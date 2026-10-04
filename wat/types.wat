	;; Consume a value declaration: scalar IDs 1..4 or reference IDs 5..6.
	(func $value-type
		(result i32)

		;; Existing i32 declarations retain type ID one.
		(if (call $is-word (i32.const 23) (i32.const 3))
			(then
				(call $next)
				(return (i32.const 1))
			)
		)
		;; Wide integers use type ID two throughout validation and host metadata.
		(if (call $is-word (i32.const 120) (i32.const 3))
			(then
				(call $next)
				(return (i32.const 2))
			)
		)
		;; Floating-point declarations use distinct types while their values retain raw IEEE bits.
		(if (call $is-word (i32.const 3860) (i32.const 3))
			(then
				(call $next)
				(return (i32.const 3))
			)
		)
		;; Double precision uses type four in signatures, locals and globals.
		(if (call $is-word (i32.const 3863) (i32.const 3))
			(then
				(call $next)
				(return (i32.const 4))
			)
		)
		;; Function references occupy type five and share the eight-byte value slot.
		(if (call $is-word (i32.const 3845) (i32.const 7))
			(then
				(call $next)
				(return (i32.const 5))
			)
		)
		;; External references occupy type six, with zero reserved for null.
		(if (call $is-word (i32.const 3893) (i32.const 9))
			(then
				(call $next)
				(return (i32.const 6))
			)
		)
		;; Vector type seven carries a low slot and a parallel high-half slot.
		(if (call $is-word (i32.const 3984) (i32.const 4))
			(then
				(call $next)
				(return (i32.const 7))
			)
		)
		(call $fail (i32.const 2))
		(i32.const 0)
	)

	;; Locate a function's local-type byte; parameters occupy the first slots.
	(func $local-type
		(param $function i32)
		(param $index i32)
		(result i32)

		(i32.add
			(global.get $local-type-base)
			(i32.add (i32.mul (local.get $function) (i32.const CAP_LOCALS)) (local.get $index))
		)
	)

	;; Resolve an initializer global.get and require an imported immutable global of the expected scalar type.
	(func $read-initializer-global
		(param $type i32)
		(local $value i32)
		(local $length i32)
		(local $source i32)
		(local $record i32)

		(call $next)
		(local.set $source (global.get $tok))
		;; Named and numeric references share the completed imported-global prefix.
		(if (call $named)
			(then
				(local.set $value (global.get $tok))
				(local.set $length (global.get $len))
				(call $next)
			)
			;; Numeric references consume one unsigned index token.
			(else
				(local.set $value (call $index))
			)
		)
		(local.set $value
			(call $resource-target
				(i32.const 2)
				(local.get $value)
				(local.get $length)
				(local.get $source)
			)
		)
		;; Invalid references must not be dereferenced as a global descriptor.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $record (call $global-record (local.get $value)))
		;; MVP constant expressions read only immutable imported globals of their own type.
		(if
			(i32.or
				(i32.eqz (i32.load offset=36 (local.get $record)))
				(i32.or
					(i32.load offset=8 (local.get $record))
					(i32.ne (i32.load offset=12 (local.get $record)) (local.get $type))
				)
			)
			(then
				(call $fail (i32.const 7))
				(return)
			)
		)
		(global.set $initializer-reference (i32.add (local.get $value) (i32.const 1)))
	)

	;; Decode a constant initializer of exactly the declared scalar type.
	(func $global-initializer
		(param $type i32)
		(result i64)
		(local $op i32)
		(local $value i64)

		(global.set $initializer-reference (i32.const 0))
		(global.set $initializer-high (i64.const 0))
		(global.set $initializer-function-present (i32.const 0))
		(call $expect (i32.const 1))
		(local.set $op (call $opcode))
		;; Vector constants initialize both raw halves without using host numeric conversions.
		(if (i32.eq (local.get $op) (i32.const 202))
			(then
				;; The initializer result must match the declared vector type.
				(if (i32.ne (local.get $type) (i32.const 7))
					(then
						(call $fail (i32.const 7))
						(return (i64.const 0))
					)
				)
				(call $next)
				(local.set $op (call $vector-literal))
				(local.set $value (i64.load (local.get $op)))
				(global.set $initializer-high (i64.load offset=8 (local.get $op)))
				(call $expect (i32.const 2))
				(return (local.get $value))
			)
		)
		;; Imported globals are evaluated after their raw values have been bound by the host.
		(if (i32.eq (local.get $op) (i32.const 49))
			(then
				(call $read-initializer-global (local.get $type))
				(call $expect (i32.const 2))
				(return (i64.const 0))
			)
		)
		;; Function initializers may name later declarations and themselves declare that function reference.
		(if (i32.eq (local.get $op) (i32.const 195))
			(then
				;; A function reference cannot initialize an external or numeric global.
				(if (i32.ne (local.get $type) (i32.const 5))
					(then
						(call $fail (i32.const 7))
					)
				)
				(call $next)
				(global.set $initializer-function-source (global.get $tok))
				(global.set $initializer-function (call $function-reference))
				(global.set $initializer-function-length (global.get $immediate-length))
				(global.set $initializer-function-present (i32.const 1))
				(call $expect (i32.const 2))
				(return (i64.const 0))
			)
		)
		;; Null initializers preserve their declared reference type without needing a table.
		(if (i32.eq (local.get $op) (i32.const 193))
			(then
				(call $next)
				;; The null heap type must agree with the global's exact reference type.
				(if (i32.ne (call $reference-type) (local.get $type))
					(then
						(call $fail (i32.const 7))
					)
				)
				(call $expect (i32.const 2))
				(return (i64.const 0))
			)
		)
		;; Only scalar constants are permitted, and their result type must match the global.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const 1))
				(i32.or
					(i32.eq (local.get $op) (i32.const 61))
					(i32.or (i32.eq (local.get $op) (i32.const 106)) (i32.eq (local.get $op) (i32.const 127)))
				)
			)
			(then
				;; Constants of a different type fail typed validation.
				(if (i32.ne (call $output-type (local.get $op)) (local.get $type))
					(then
						(call $fail (i32.const 7))
						(return (i64.const 0))
					)
				)
			)
			;; Other initializer expressions remain unsupported.
			(else
				(call $fail (i32.const 2))
				(return (i64.const 0))
			)
		)
		(call $next)
		;; Floating constants are parsed and rounded entirely inside the interpreter.
		(if (i32.ge_u (local.get $type) (i32.const 3))
			(then
				(local.set $value (call $float-literal (local.get $type)))
			)
			;; Integer constants retain their existing lexical contracts.
			(else
				;; Wide integer literals preserve all 64 bits.
				(if (i32.eq (local.get $type) (i32.const 2))
					(then
						(local.set $value (call $integer64))
					)
					;; Narrow integers sign extend inside the shared slot.
					(else
						(local.set $value (i64.extend_i32_s (call $integer)))
					)
				)
			)
		)
		(call $expect (i32.const 2))
		(local.get $value)
	)

	;; Canonicalize 32-bit slots while preserving full-width integer and float bits.
	(func $canonical-value
		(param $value i64)
		(param $type i32)
		(result i64)

		;; Narrow integers sign extend so both ABIs observe the same value.
		(if (i32.eq (local.get $type) (i32.const 1))
			(then
				(return (i64.extend_i32_s (i32.wrap_i64 (local.get $value))))
			)
		)
		;; Single precision has no significant bits above its low word.
		(if (i32.eq (local.get $type) (i32.const 3))
			(then
				(return (i64.extend_i32_u (i32.wrap_i64 (local.get $value))))
			)
		)
		(local.get $value)
	)

	;; Query a function parameter's scalar type, checking both function and parameter bounds.
	(func (export "function_param_type")
		(param $index i32)
		(param $slot i32)
		(result i32)

		;; Invalid function indices cannot expose another arena as a type table.
		(if (i32.ge_u (local.get $index) (global.get $function-count))
			(then
				(return (i32.const 0))
			)
		)
		;; Only declared parameters are exposed by the host signature API.
		(if
			(i32.ge_u (local.get $slot) (i32.load offset=16 (call $function (local.get $index))))
			(then
				(return (i32.const 0))
			)
		)
		(i32.load8_u (call $local-type (local.get $index) (local.get $slot)))
	)

	;; Query a function result's scalar type; invalid indices return the sentinel -1.
	(func (export "function_result_type")
		(param $index i32)
		(param $slot i32)
		(result i32)

		;; Function indices are unsigned and bounded by the loaded module.
		(if (i32.ge_u (local.get $index) (global.get $function-count))
			(then
				(return (i32.const -1))
			)
		)
		(call $shape-type
			(i32.load offset=24 (call $function (local.get $index)))
			(local.get $slot)
		)
	)

	;; Consume a ref.null heap type, rejecting value types and unknown heap types.
	(func $reference-type
		(result i32)

		;; The func heap type produces a nullable function reference.
		(if (call $is-word (i32.const 6) (i32.const 4))
			(then
				(call $next)
				(return (i32.const 5))
			)
		)
		;; The extern heap type produces an opaque host reference.
		(if (call $is-word (i32.const 3902) (i32.const 6))
			(then
				(call $next)
				(return (i32.const 6))
			)
		)
		(call $fail (i32.const 1))
		(i32.const 0)
	)

	;; Resolve forward function initializers and declare those function references before body validation.
	(func $resolve-reference-globals
		(local $i i32)
		(local $record i32)
		(local $index i32)

		;; Finish after every global descriptor has been examined.
		(block $done
			;; Numeric, null and imported-global initializers need no function lookup.
			(loop $globals
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $global-count)))
				(local.set $record (call $global-record (local.get $i)))
				;; Only explicit ref.func initializers declare and initialize a function value.
				(if (i32.load offset=56 (local.get $record))
					(then
						(local.set $index
							(call $target
								(i32.load offset=44 (local.get $record))
								(i32.load offset=48 (local.get $record))
								(i32.load offset=52 (local.get $record))
							)
						)
						(call $declare-function (local.get $index))
						(i64.store offset=16
							(local.get $record)
							(i64.extend_i32_u (i32.add (local.get $index) (i32.const 1)))
						)
						(i64.store offset=24 (local.get $record) (i64.load offset=16 (local.get $record)))
						(i64.store offset=72 (local.get $record) (i64.load offset=64 (local.get $record)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $globals)
			)
		)
	)
