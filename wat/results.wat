	;; Count a result shape: zero for void, one for a scalar, or a stored type vector.
	(func $shape-count
		(param $shape i32)
		(result i32)

		;; Small shape codes are ordinary value types and avoid vector allocation.
		(if (i32.lt_u (local.get $shape) (i32.const 1048576))
			(then
				(return (i32.ne (local.get $shape) (i32.const 0)))
			)
		)
		(i32.load (local.get $shape))
	)

	;; Read one result type in declaration order from a scalar or vector shape.
	(func $shape-type
		(param $shape i32)
		(param $index i32)
		(result i32)

		;; Singleton signatures keep their original compact scalar representation.
		(if (i32.lt_u (local.get $shape) (i32.const 1048576))
			(then
				(return (local.get $shape))
			)
		)
		(i32.load offset=4
			(i32.add (local.get $shape) (i32.mul (local.get $index) (i32.const 4)))
		)
	)

	;; Append a parsed type to a bounded mutable vector, allocating only at its second result.
	(func $shape-append
		(param $shape i32)
		(param $type i32)
		(result i32)
		(local $record i32)
		(local $count i32)

		;; The first result uses its scalar type directly.
		(if (i32.eqz (local.get $shape))
			(then
				(return (local.get $type))
			)
		)
		(local.set $count (call $shape-count (local.get $shape)))
		;; Result vectors and records have independent fixed limits.
		(if (i32.ge_u (local.get $count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return (local.get $shape))
			)
		)
		(local.set $record (local.get $shape))
		;; A second type moves the singleton into a dedicated record.
		(if (i32.lt_u (local.get $shape) (i32.const 1048576))
			(then
				;; Avoid writing past the result-vector arena.
				(if (i32.ge_u (global.get $result-shape-count) (i32.const 4096))
					(then
						(call $fail (i32.const 6))
						(return (local.get $shape))
					)
				)
				(local.set $record
					(i32.add
						(global.get $result-shape-base)
						(i32.mul (global.get $result-shape-count) (i32.const 516))
					)
				)
				(global.set $result-shape-count (i32.add (global.get $result-shape-count) (i32.const 1)))
				(i32.store offset=4 (local.get $record) (local.get $shape))
			)
		)
		(i32.store offset=4
			(i32.add (local.get $record) (i32.mul (local.get $count) (i32.const 4)))
			(local.get $type)
		)
		(i32.store (local.get $record) (i32.add (local.get $count) (i32.const 1)))
		(local.get $record)
	)

	;; Compare result vectors structurally rather than by arena addresses.
	(func $shape-equal
		(param $a i32)
		(param $b i32)
		(result i32)
		(local $i i32)
		(local $count i32)

		(local.set $count (call $shape-count (local.get $a)))
		;; Different lengths cannot describe the same signature.
		(if (i32.ne (local.get $count) (call $shape-count (local.get $b)))
			(then
				(return (i32.const 0))
			)
		)
		;; Finish after every ordered type matches.
		(block $done
			;; This also handles void and singleton signatures without special equality rules.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; One differing scalar/reference type invalidates structural equality.
				(if
					(i32.eqz
						(call $type-equal
							(call $shape-type (local.get $a) (local.get $i))
							(call $shape-type (local.get $b) (local.get $i))
						)
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
		(i32.const 1)
	)

	;; Publish a shape's complete ordered type vector onto the abstract operand stack.
	(func $validation-publish
		(param $shape i32)
		(local $i i32)

		;; Finish after all result types have been pushed.
		(block $done
			;; The ordinary bounded push handles every scalar and reference type.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (call $shape-count (local.get $shape))))
				(call $validation-value (call $shape-type (local.get $shape) (local.get $i)))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
	)

	;; Check a branch target against actual operands without destroying polymorphic unknown types.
	(func $validation-check-shape
		(param $shape i32)
		(local $i i32)
		(local $count i32)
		(local $floor i32)
		(local $type i32)
		(local $frame i32)

		(local.set $count (call $shape-count (local.get $shape)))
		(local.set $frame (call $control (i32.sub (global.get $control-count) (i32.const 1))))
		(local.set $floor (i32.load offset=4 (local.get $frame)))
		;; Check each expected top value against the same unmodified abstract stack.
		(block $done
			;; Missing values at an unreachable floor have unknown type zero.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(local.set $type (i32.const 0))
				;; Concrete operands above the control floor retain their type even in dead code.
				(if (i32.lt_u (local.get $i) (i32.sub (global.get $depth) (local.get $floor)))
					(then
						(local.set $type
							(i32.load
								(i32.add
									(global.get $type-stack-base)
									(i32.mul
										(i32.sub (i32.sub (global.get $depth) (i32.const 1)) (local.get $i))
										(i32.const 4)
									)
								)
							)
						)
					)
					;; A reachable floor cannot synthesize missing branch operands.
					(else
						;; Only an unreachable control floor may supply unknown missing operands.
						(if (i32.eqz (i32.load offset=12 (local.get $frame)))
							(then
								(call $fail (i32.const 7))
							)
						)
					)
				)
				;; Unknown operands satisfy any expected type, while known types must match.
				(if
					(i32.and
						(local.get $type)
						(i32.eqz
							(call $type-compatible
								(local.get $type)
								(call $shape-type
									(local.get $shape)
									(i32.sub (i32.sub (local.get $count) (i32.const 1)) (local.get $i))
								)
							)
						)
					)
					(then
						(call $fail (i32.const 7))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
	)

	;; Expose completed result slots to the trusted host adapter for multivalue returns.
	(func (export "result_base")
		(result i32)

		(global.get $stack-base)
	)

	;; Resolve deferred control signatures into result and parameter shapes after all type declarations.
	(func $resolve-control-signatures
		(local $i i32)
		(local $record i32)
		(local $signature i32)
		(local $shape i32)
		(local $j i32)

		;; Finish after inspecting every normalized instruction.
		(block $done
			;; Only structured entries can carry a negative deferred signature index.
			(loop $instructions
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $code-count)))
				(local.set $record
					(i32.add (global.get $code-base) (i32.mul (local.get $i) (i32.const 16)))
				)
				;; Ordinary scalar/vector result shapes are already final.
				(if
					(i32.and
						(call $control-op (i32.load (local.get $record)))
						(i32.lt_s (i32.load offset=4 (local.get $record)) (i32.const 0))
					)
					(then
						(local.set $signature
							(call $signature (i32.sub (i32.const -1) (i32.load offset=4 (local.get $record))))
						)
						(i32.store offset=4 (local.get $record) (i32.load offset=12 (local.get $signature)))
						(local.set $shape (i32.const 0))
						(local.set $j (i32.const 0))
						;; Finish after collecting the complete input type vector.
						(block $params-done
							;; Control inputs use the same structural shape representation as outputs.
							(loop $params
								(br_if $params-done (global.get $error))
								(br_if $params-done (i32.eq (local.get $j) (i32.load offset=8 (local.get $signature))))
								(local.set $shape
									(call $shape-append
										(local.get $shape)
										(i32.load offset=32
											(i32.add (local.get $signature) (i32.mul (local.get $j) (i32.const 4)))
										)
									)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $params)
							)
						)
						(i32.store offset=20 (call $metadata (local.get $i)) (local.get $shape))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $instructions)
			)
		)
	)

	;; Locate the parallel high half of a protected stack or normalized argument slot.
	(func $slot-high-address
		(param $address i32)
		(result i32)

		;; Defined calls read parameters from the operand stack.
		(if
			(i32.and
				(i32.ge_u (local.get $address) (global.get $stack-base))
				(i32.lt_u (local.get $address) (i32.add (global.get $stack-base) (i32.const 32768)))
			)
			(then
				(return
					(i32.add
						(global.get $stack-high-base)
						(i32.sub (local.get $address) (global.get $stack-base))
					)
				)
			)
		)
		(i32.add
			(global.get $argument-high-base)
			(i32.sub (local.get $address) (global.get $argument-base))
		)
	)

	;; Locate one call frame's parameter/local high-half slot.
	(func $local-high-address
		(param $frame i32)
		(param $index i32)
		(result i32)

		(i32.add
			(global.get $call-high-base)
			(i32.add
				(i32.mul
					(i32.div_u (i32.sub (local.get $frame) (global.get $call-base)) (i32.const CALL_BYTES))
					(i32.const LOCAL_NAME_BYTES)
				)
				(i32.mul (local.get $index) (i32.const 8))
			)
		)
	)

	;; Expose normalized argument high halves to the trusted synchronous host adapter.
	(func (export "argument_high_base")
		(result i32)

		(global.get $argument-high-base)
	)

	;; Expose pending import argument/result high halves above the saved operand cursor.
	(func (export "pending_high_args")
		(result i32)

		(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
	)

	;; Expose completed result high halves in declaration order.
	(func (export "result_high_base")
		(result i32)

		(global.get $stack-high-base)
	)

	;; Check whether every actual result satisfies the enclosing expected result vector.
	(func $shape-compatible
		(param $actual i32)
		(param $expected i32)
		(result i32)
		(local $i i32)

		;; Different result arities are incompatible.
		(if
			(i32.ne (call $shape-count (local.get $actual)) (call $shape-count (local.get $expected)))
			(then
				(return (i32.const 0))
			)
		)
		;; Finish after all result slots satisfy value subtyping.
		(block $done
			;; Results are covariant in tail calls and declared function subtypes.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (call $shape-count (local.get $actual))))
				;; Every ordered result must satisfy the corresponding expected type.
				(if
					(i32.eqz
						(call $type-compatible
							(call $shape-type (local.get $actual) (local.get $i))
							(call $shape-type (local.get $expected) (local.get $i))
						)
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
		(i32.const 1)
	)
