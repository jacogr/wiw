	;; Distinguish the resolved constant replay from forward declaration parsing.
	(global $initializer-evaluating (mut i32) (i32.const 0))
	;; Consume a value declaration: scalar IDs 1..4 or reference IDs 5..6.
	(func $value-type
		(result i32)
		(local $type i32)

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
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 12))
			(then
				(call $next)
				(return (i32.const 16))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 13))
			(then
				(call $next)
				(return (i32.const 18))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 14))
			(then
				(call $next)
				(return (i32.const 20))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 15))
			(then
				(call $next)
				(return (i32.const 22))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 16))
			(then
				(call $next)
				(return (i32.const 24))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 17))
			(then
				(call $next)
				(return (i32.const 26))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 18))
			(then
				(call $next)
				(return (i32.const 28))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 19))
			(then
				(call $next)
				(return (i32.const 30))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 20))
			(then
				(call $next)
				(return (i32.const 32))
			)
		)
		;; Recognize an abstract nullable reference alias.
		(if (call $is-ref-word (i32.const 21))
			(then
				(call $next)
				(return (i32.const 34))
			)
		)
		;; Explicit reference types retain nullability and a deferred heap type.
		(if (i32.eq (global.get $kind) (i32.const 1))
			(then
				(call $next)
				;; Require the ref keyword before parsing an explicit reference type.
				(if (i32.eqz (call $is-ref-word (i32.const 0)))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return (i32.const 0))
					)
				)
				(call $next)
				;; Nullable references include the null keyword before the heap type.
				(if (call $is-ref-word (i32.const 1))
					(then
						(call $next)
						(local.set $type (call $reference-type))
					)
					;; Non-null reference declarations use the same heap descriptor.
					(else
						(local.set $type (call $reference-nonnull-type (call $reference-type)))
					)
				)
				(call $expect (i32.const 2))
				(return (local.get $type))
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
		(i32.const 0)
	)

	;; Locate a function's local-type slot; parameters occupy the first slots.
	(func $local-type
		(param $function i32)
		(param $index i32)
		(result i32)

		(i32.add
			(global.get $local-type-base)
			(i32.mul
				(i32.add (i32.mul (local.get $function) (i32.const M4_CAP_LOCALS)) (local.get $index))
				(i32.const 4)
			)
		)
	)

	;; Resolve an initializer global.get and require an earlier immutable global of the expected scalar type.
	(func $read-initializer-global
		(param $type i32)
		(local $value i32)
		(local $length i32)
		(local $source i32)
		(local $record i32)

		(call $next)
		(local.set $source (global.get $tok))
		;; Named and numeric references share the completed global prefix.
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
		;; Constant expressions read earlier immutable globals of their own type.
		(if
			(i32.or
				(i32.load offset=8 (local.get $record))
				(i32.eqz
					(call $type-compatible (i32.load offset=12 (local.get $record)) (local.get $type))
				)
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(global.set $initializer-reference (i32.add (local.get $value) (i32.const 1)))
	)

	;; Decode a constant initializer of exactly the declared scalar type.
	(func $global-initializer-body
		(param $type i32)
		(result i64)
		(local $op i32)
		(local $value i64)
		(local $source i32)
		(local $deferred i32)
		(local $a i64)
		(local $b i64)

		(local.set $source (global.get $tok))
		(global.set $initializer-reference (i32.const 0))
		(global.set $initializer-high (i64.const 0))
		(global.set $initializer-function-present (i32.const 0))
		(call $expect (i32.const 1))
		(local.set $op (call $opcode))
		;; Aggregate constructors are evaluated again after immutable imported values are bound.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW)) (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT)))
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_NEW))
					(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
				)
			)
			(then
				(local.set $value (call $gc-constant (local.get $op) (local.get $type)))
				(global.set $initializer-reference (i32.sub (i32.const 0) (local.get $source)))
				(return (local.get $value))
			)
		)
		;; Extended integer expressions compose add, subtract and multiply with typed constant operands.
		(if
			(i32.or
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_I32_ADD))
					(i32.le_u (local.get $op) (i32.const M4_OP_I32_MUL))
				)
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_I64_ADD))
					(i32.le_u (local.get $op) (i32.const M4_OP_I64_MUL))
				)
			)
			(then
				;; Integer width is checked before recursive operand parsing.
				(if (i32.ne (call $output-type (local.get $op)) (local.get $type))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
						(return (i64.const 0))
					)
				)
				(call $next)
				(local.set $a (call $global-initializer (local.get $type)))
				(local.set $deferred (i32.ne (global.get $initializer-reference) (i32.const 0)))
				(local.set $b (call $global-initializer (local.get $type)))
				(local.set $deferred
					(i32.or (local.get $deferred) (i32.ne (global.get $initializer-reference) (i32.const 0)))
				)
				(call $expect (i32.const 2))
				(global.set $initializer-reference
					(select (i32.sub (i32.const 0) (local.get $source)) (i32.const 0) (local.get $deferred))
				)
				;; Wide operations retain all bits; narrow operations wrap and sign extend their result.
				(if (i32.eq (local.get $type) (i32.const 2))
					(then
						(return (call $apply64 (local.get $op) (local.get $a) (local.get $b)))
					)
				)
				(return
					(i64.extend_i32_s
						(call $apply (local.get $op) (i32.wrap_i64 (local.get $a)) (i32.wrap_i64 (local.get $b)))
					)
				)
			)
		)
		;; Small integer constant expressions truncate their i32 operand to the i31 payload.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_I31))
			(then
				;; The non-null i31 result must fit the declared reference type.
				(if (i32.eqz (call $type-compatible (i32.const 21) (local.get $type)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(call $next)
				(local.set $a (call $global-initializer (i32.const 1)))
				(local.set $deferred (global.get $initializer-reference))
				(call $expect (i32.const 2))
				(global.set $initializer-reference
					(select (i32.sub (i32.const 0) (local.get $source)) (i32.const 0) (local.get $deferred))
				)
				(return
					(call $gc-reference-apply (local.get $op) (local.get $a) (i64.const 0) (i32.const 0))
				)
			)
		)
		;; Reference conversions are constant expressions and preserve opaque host identity.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ANY_CONVERT_EXTERN)) (i32.eq (local.get $op) (i32.const M4_OP_EXTERN_CONVERT_ANY)))
			(then
				(call $next)
				(local.set $a
					(call $global-initializer
						(select (i32.const 6) (i32.const 16) (i32.eq (local.get $op) (i32.const M4_OP_ANY_CONVERT_EXTERN)))
					)
				)
				(local.set $deferred (global.get $initializer-reference))
				(call $expect (i32.const 2))
				;; Conversion result types remain within their distinct abstract reference hierarchy.
				(if
					(i32.eqz
						(call $type-compatible
							(select (i32.const 16) (i32.const 6) (i32.eq (local.get $op) (i32.const M4_OP_ANY_CONVERT_EXTERN)))
							(local.get $type)
						)
					)
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(global.set $initializer-reference
					(select (i32.sub (i32.const 0) (local.get $source)) (i32.const 0) (local.get $deferred))
				)
				(return
					(call $gc-reference-apply (local.get $op) (local.get $a) (i64.const 0) (i32.const 0))
				)
			)
		)
		;; Vector constants initialize both raw halves without using host numeric conversions.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_CONST))
			(then
				;; The initializer result must match the declared vector type.
				(if (i32.ne (local.get $type) (i32.const 7))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
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
		(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET))
			(then
				(call $read-initializer-global (local.get $type))
				(call $expect (i32.const 2))
				;; Invalid references must not become backing-memory addresses.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(global.set $initializer-high
					(i64.load offset=72
						(call $canonical-global-record
							(i32.sub (global.get $initializer-reference) (i32.const 1))
						)
					)
				)
				(return
					(i64.load offset=24
						(call $canonical-global-record
							(i32.sub (global.get $initializer-reference) (i32.const 1))
						)
					)
				)
			)
		)
		;; Function initializers may name later declarations and themselves declare that function reference.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_FUNC))
			(then
				;; A function reference cannot initialize an external or numeric global.
				(if
					;; Abstract reference types can be checked before concrete forward types resolve.
					(if (result i32) (i32.lt_u (local.get $type) (i32.const 64))
						(then
							(i32.eqz (call $type-compatible (local.get $type) (i32.const 5)))
						)
						;; Concrete forward heap types are checked after type namespace resolution.
						(else
							(i32.const 0)
						)
					)
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(call $next)
				(global.set $initializer-function-source (global.get $tok))
				(global.set $initializer-function (call $function-reference))
				(global.set $initializer-function-length (global.get $immediate-length))
				(global.set $initializer-function-present (i32.const 1))
				(call $expect (i32.const 2))
				;; Resolved replay initializes nested function values and declares their referenced function.
				(if (global.get $initializer-evaluating)
					(then
						(local.set $op
							(call $target
								(global.get $initializer-function)
								(global.get $initializer-function-length)
								(global.get $initializer-function-source)
							)
						)
						;; The precise function type must satisfy its enclosing aggregate field.
						(if
							(i32.eqz
								(call $type-compatible (call $function-reference-type (local.get $op)) (local.get $type))
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
						(call $declare-function (local.get $op))
						(return (i64.extend_i32_u (i32.add (local.get $op) (i32.const 1))))
					)
				)
				(return (i64.const 0))
			)
		)
		;; Null initializers preserve their declared reference type without needing a table.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_NULL))
			(then
				(call $next)
				;; The null heap type must agree with the global's exact reference type.
				(if (i32.eqz (call $type-compatible (call $reference-type) (local.get $type)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(call $expect (i32.const 2))
				(return (i64.const 0))
			)
		)
		;; Only scalar constants are permitted, and their result type must match the global.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const M4_OP_I32_CONST))
				(i32.or
					(i32.eq (local.get $op) (i32.const M4_OP_I64_CONST))
					(i32.or (i32.eq (local.get $op) (i32.const M4_OP_F32_CONST)) (i32.eq (local.get $op) (i32.const M4_OP_F64_CONST)))
				)
			)
			(then
				;; Constants of a different type fail typed validation.
				(if (i32.ne (call $output-type (local.get $op)) (local.get $type))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
						(return (i64.const 0))
					)
				)
			)
			;; Other initializer expressions remain unsupported.
			(else
				(call $fail (i32.const M4_ERR_UNSUPPORTED))
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
		(call $value-kind (i32.load (call $local-type (local.get $index) (local.get $slot))))
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
		(call $value-kind
			(call $shape-type
				(i32.load offset=24 (call $function (local.get $index)))
				(local.get $slot)
			)
		)
	)

	;; Consume a ref.null heap type, rejecting value types and unknown heap types.
	(func $reference-type
		(result i32)
		(local $source i32)
		(local $value i32)
		(local $length i32)

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
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 2))
			(then
				(call $next)
				(return (i32.const 16))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 3))
			(then
				(call $next)
				(return (i32.const 18))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 4))
			(then
				(call $next)
				(return (i32.const 20))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 5))
			(then
				(call $next)
				(return (i32.const 22))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 6))
			(then
				(call $next)
				(return (i32.const 24))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 7))
			(then
				(call $next)
				(return (i32.const 26))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 8))
			(then
				(call $next)
				(return (i32.const 28))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 9))
			(then
				(call $next)
				(return (i32.const 30))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 10))
			(then
				(call $next)
				(return (i32.const 32))
			)
		)
		;; Recognize this abstract heap type in reference declarations and null instructions.
		(if (call $is-ref-word (i32.const 11))
			(then
				(call $next)
				(return (i32.const 34))
			)
		)
		;; Named or numeric heap types resolve after the complete module has been parsed.
		(if (i32.or (call $named) (call $index-token))
			(then
				(local.set $source (global.get $tok))
				;; Named references keep their source span until resolution.
				(if (call $named)
					(then
						(local.set $value (global.get $tok))
						(local.set $length (global.get $len))
						(call $next)
					)
					;; Numeric references preserve the type namespace index.
					(else
						(local.set $value (call $index))
					)
				)
				(return
					(call $intern-reference-type
						(local.get $value)
						(local.get $length)
						(local.get $source)
						(i32.const 0)
					)
				)
			)
		)
		(call $fail (i32.const M4_ERR_SYNTAX))
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
				;; Replay folded constants after name resolution so nested ref.func expressions declare their targets.
				(if (i32.lt_s (i32.load offset=40 (local.get $record)) (i32.const 0))
					(then
						(i64.store offset=16
							(local.get $record)
							(call $initializer-value
								(i32.load offset=40 (local.get $record))
								(i32.load offset=12 (local.get $record))
							)
						)
						(i64.store offset=24 (local.get $record) (i64.load offset=16 (local.get $record)))
					)
				)
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
						;; The resolved function's precise type must satisfy the declared global type.
						(if
							(i32.eqz
								(call $type-compatible
									(call $function-reference-type (local.get $index))
									(i32.load offset=12 (local.get $record))
								)
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
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

	;; Bound recursively folded constant expressions without allowing the native stack to grow indefinitely.
	(func $global-initializer
		(param $type i32)
		(result i64)
		(local $value i64)

		;; A prior error or excessive nesting terminates this constant expression.
		(if
			(i32.or (global.get $error) (i32.ge_u (global.get $constant-depth) (i32.const 256)))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i64.const 0))
			)
		)
		(global.set $constant-depth (i32.add (global.get $constant-depth) (i32.const 1)))
		(local.set $value (call $global-initializer-body (local.get $type)))
		(global.set $constant-depth (i32.sub (global.get $constant-depth) (i32.const 1)))
		(local.get $value)
	)

	;; Evaluate a deferred imported-global reference or constant expression while preserving the parser cursor.
	(func $initializer-value
		(param $reference i32)
		(param $type i32)
		(result i64)
		(local $pos i32)
		(local $tok i32)
		(local $len i32)
		(local $kind i32)
		(local $value i64)
		(local $evaluating i32)

		;; Positive references retain the existing global-index-plus-one encoding.
		(if (i32.gt_s (local.get $reference) (i32.const 0))
			(then
				(return
					(i64.load offset=24
						(call $canonical-global-record (i32.sub (local.get $reference) (i32.const 1)))
					)
				)
			)
		)
		(local.set $pos (global.get $pos))
		(local.set $tok (global.get $tok))
		(local.set $len (global.get $len))
		(local.set $kind (global.get $kind))
		(global.set $pos (i32.sub (i32.const 0) (local.get $reference)))
		(call $next)
		(local.set $evaluating (global.get $initializer-evaluating))
		(global.set $initializer-evaluating (i32.const 1))
		(local.set $value (call $global-initializer (local.get $type)))
		(global.set $initializer-evaluating (local.get $evaluating))
		(global.set $pos (local.get $pos))
		(global.set $tok (local.get $tok))
		(global.set $len (local.get $len))
		(global.set $kind (local.get $kind))
		(local.get $value)
	)
