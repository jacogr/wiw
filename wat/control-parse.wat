	;; Locate a 32-byte syntax frame for a folded expression, control scope or arm wrapper.
	(func $syntax
		(param $index i32)
		(result i32)

		(i32.add (global.get $frame-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Locate per-instruction control metadata: matching end, else, result type and label span.
	(func $metadata
		(param $index i32)
		(result i32)

		(i32.add (global.get $metadata-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Push syntax state without native recursion; mode determines how its closing token is handled.
	;; Fields 0/4/8/12: opcode, immediate/start, source offset, name length/result type.
	;; Fields 16/20/24: mode, label pointer, label length.
	(func $push-syntax
		(param $op i32)
		(param $value i32)
		(param $offset i32)
		(param $extra i32)
		(param $mode i32)
		(param $label i32)
		(param $length i32)
		(local $frame i32)

		;; Bound all nested syntax, including flat controls and folded expressions.
		(if (i32.ge_u (global.get $syntax-count) (i32.const 256))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(local.set $frame (call $syntax (global.get $syntax-count)))
		(i32.store (local.get $frame) (local.get $op))
		(i32.store offset=4 (local.get $frame) (local.get $value))
		(i32.store offset=8 (local.get $frame) (local.get $offset))
		(i32.store offset=12 (local.get $frame) (local.get $extra))
		(i32.store offset=16 (local.get $frame) (local.get $mode))
		(i32.store offset=20 (local.get $frame) (local.get $label))
		(i32.store offset=24 (local.get $frame) (local.get $length))
		(i32.store offset=28 (local.get $frame) (i32.const 0))
		(global.set $syntax-count (i32.add (global.get $syntax-count) (i32.const 1)))
	)

	;; Emit a control entry and initialize its matching-boundary metadata.
	;; Folded if defers this until its condition expressions have finished.
	(func $start-control
		(param $frame i32)
		(local $start i32)
		(local $meta i32)

		(local.set $start (global.get $code-count))
		(call $emit
			(i32.load (local.get $frame))
			(i32.load offset=12 (local.get $frame))
			(i32.load offset=8 (local.get $frame))
			(i32.const 0)
		)
		;; Failed emission cannot be followed by an out-of-range metadata write.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(i32.store offset=4 (local.get $frame) (local.get $start))
		(local.set $meta (call $metadata (local.get $start)))
		(i32.store (local.get $meta) (i32.const -1))
		(i32.store offset=4 (local.get $meta) (i32.const -1))
		(i32.store offset=20 (local.get $meta) (i32.const 0))
		(i32.store offset=8 (local.get $meta) (i32.load offset=12 (local.get $frame)))
		(i32.store offset=12 (local.get $meta) (i32.load offset=20 (local.get $frame)))
		(i32.store offset=16 (local.get $meta) (i32.load offset=24 (local.get $frame)))
		(i32.store offset=24 (local.get $meta) (i32.load offset=28 (local.get $frame)))
	)

	;; Emit an end marker and patch its opening control to the matching instruction index.
	(func $close-control
		(param $frame i32)
		(param $offset i32)
		(local $end i32)

		(local.set $end (global.get $code-count))
		(call $emit
			(i32.const M4_OP_END)
			(i32.load offset=4 (local.get $frame))
			(local.get $offset)
			(i32.const 0)
		)
		;; Patch only after a successful append, preserving the instruction capacity invariant.
		(if (i32.eqz (global.get $error))
			(then
				(i32.store (call $metadata (i32.load offset=4 (local.get $frame))) (local.get $end))
			)
		)
	)

	;; Emit one else marker for an if and patch the false-path boundary.
	(func $else-control
		(param $frame i32)
		(param $offset i32)
		(local $meta i32)
		(local $at i32)

		(local.set $meta (call $metadata (i32.load offset=4 (local.get $frame))))
		;; An if may have at most one else arm.
		(if (i32.ne (i32.load offset=4 (local.get $meta)) (i32.const -1))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		(local.set $at (global.get $code-count))
		(call $emit
			(i32.const M4_OP_ELSE)
			(i32.load offset=4 (local.get $frame))
			(local.get $offset)
			(i32.const 0)
		)
		;; Keep the false-path index valid even when the instruction table is full.
		(if (i32.eqz (global.get $error))
			(then
				(i32.store offset=4 (local.get $meta) (local.get $at))
			)
		)
	)

	;; Collect repeated block result groups, replaying the first body opening.
	(func $block-result
		(result i32)
		(local $open i32)
		(local $shape i32)

		;; Stop at the first token that belongs to the block body.
		(block $done
			;; Repeated result groups extend the same ordered shape.
			(loop $groups
				(br_if $done (global.get $error))
				(br_if $done (i32.ne (global.get $kind) (i32.const 1)))
				(local.set $open (global.get $tok))
				(call $next)
				;; Parameter/type-use headers retain a deferred structural signature.
				(if
					(i32.or
						(call $is-word (i32.const 64) (i32.const 5))
						(call $is-word (i32.const 3856) (i32.const 4))
					)
					(then
						;; Parameter declarations cannot follow result declarations.
						(if (local.get $shape)
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return (i32.const 0))
							)
						)
						(global.set $pos (local.get $open))
						(call $next)
						(return (i32.sub (i32.const -1) (call $indirect-signature)))
					)
				)
				;; Other declaration heads are left to subsequent control-signature support.
				(if (i32.eqz (call $is-word (i32.const 17) (i32.const 6)))
					(then
						(global.set $pos (local.get $open))
						(call $next)
						(br $done)
					)
				)
				(call $next)
				;; Finish the current group at its close or an earlier error.
				(block $types-done
					;; Append every type without imposing singleton result arity.
					(loop $types
						(br_if $types-done (global.get $error))
						(br_if $types-done (i32.eq (global.get $kind) (i32.const 2)))
						(local.set $shape (call $shape-append (local.get $shape) (call $value-type)))
						(br $types)
					)
				)
				(call $expect (i32.const 2))
				(br $groups)
			)
		)
		(local.get $shape)
	)

	;; Resolve a branch label to control depth, ignoring ordinary expression/arm syntax frames.
	;; Numeric depth includes the implicit function label; function identifiers are not label names.
	(func $label
		(result i32)
		(local $i i32)
		(local $depth i32)
		(local $frame i32)
		(local $named i32)
		(local $p i32)
		(local $n i32)
		(local $value i32)

		(local.set $named (call $named))
		(local.set $p (global.get $tok))
		(local.set $n (global.get $len))
		(local.set $i (global.get $syntax-count))
		;; Finish after all active explicit control scopes have been counted.
		(block $done
			;; Search from the innermost label outward, so duplicate label names shadow outer scopes.
			(loop $scopes
				(br_if $done (i32.eqz (local.get $i)))
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				(local.set $frame (call $syntax (local.get $i)))
				;; A pending folded-if condition runs outside that if's label scope.
				(if
					(i32.and
						(call $control-op (i32.load (local.get $frame)))
						(i32.ne (i32.load offset=4 (local.get $frame)) (i32.const -1))
					)
					(then
						;; Named references choose the nearest active label with the same identifier span.
						(if
							(i32.and
								(local.get $named)
								;; Compare bytes only after the complete span/prefix guard succeeds.
								(if (result i32)
									(i32.eq (local.get $n) (i32.load offset=24 (local.get $frame)))
									(then
										(call $equal (local.get $p) (i32.load offset=20 (local.get $frame)) (local.get $n))
									)
									;; An incompatible span cannot match this name or prefix.
									(else (i32.const 0))
								)
							)
							(then
								(call $next)
								(return (local.get $depth))
							)
						)
						(local.set $depth (i32.add (local.get $depth) (i32.const 1)))
					)
				)
				(br $scopes)
			)
		)
		;; An unmatched identifier cannot refer to the unnamed implicit function label.
		(if (local.get $named)
			(then
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
				(return (i32.const 0))
			)
		)
		(local.set $value (call $index))
		;; Numeric depths may select an explicit scope or the implicit function scope above them.
		(if (i32.gt_u (local.get $value) (local.get $depth))
			(then
				(global.set $tok (local.get $p))
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
			)
		)
		(local.get $value)
	)

	;; Check an optional identifier repeated after flat else/end against its opening control label.
	(func $repeat-label
		(param $frame i32)

		;; Unnamed closing markers need no identifier check.
		(if (call $named)
			(then
				;; A repeated label must exactly match this control's declared identifier.
				(if
					(i32.eqz
						;; Compare bytes only after the complete span/prefix guard succeeds.
						(if (result i32)
							(i32.eq (global.get $len) (i32.load offset=24 (local.get $frame)))
							(then
								(call $equal (global.get $tok) (i32.load offset=20 (local.get $frame)) (global.get $len))
							)
							;; An incompatible span cannot match this name or prefix.
							(else (i32.const 0))
						)
					)
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
					)
				)
				(call $next)
			)
		)
	)

	;; Decode immediates and expose reference-name lengths, branch-table sizes or memory alignment.
	(func $instruction-immediate
		(param $op i32)
		(result i32)
		(local $value i32)
		(local $length i32)
		(local $start i32)
		(local $wide i64)

		(global.set $immediate-length (i32.const 0))
		;; Memory selectors precede folded operands and retain forward references until validation.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_SIZE)) (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_GROW)))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_COPY)) (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_FILL)))
			)
			(then
				(return (call $memory-immediate (local.get $op)))
			)
		)
		;; Data initialization retains separate memory and segment namespaces.
		(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_INIT))
			(then
				(return (call $memory-init-immediate))
			)
		)
		;; Throws preserve late-bound tag names in a private immediate descriptor.
		(if (i32.eq (local.get $op) (i32.const M4_OP_THROW))
			(then
				(local.set $value (call $new-memory-immediate))
				(i32.store offset=8 (local.get $value) (global.get $tok))
				(i32.store (local.get $value) (call $function-reference))
				(i32.store offset=4 (local.get $value) (global.get $immediate-length))
				(return (local.get $value))
			)
		)
		;; Cast branches retain their resolved label and both explicit reference types.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST)) (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST_FAIL)))
			(then
				(local.set $value (call $new-memory-immediate))
				(i32.store (local.get $value) (call $label))
				(i32.store offset=4 (local.get $value) (call $value-type))
				(i32.store offset=8 (local.get $value) (call $value-type))
				(return (local.get $value))
			)
		)
		;; Aggregate operators preserve type and field or segment immediates for late resolution.
		(if
			(i32.and
				(i32.ge_u (local.get $op) (i32.const M4_OP_STRUCT_NEW))
				(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_INIT_ELEM))
			)
			(then
				(return (call $gc-immediate (local.get $op)))
			)
		)
		;; Casts and tests retain the complete target reference type, including nullability.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_REF_TEST)) (i32.eq (local.get $op) (i32.const M4_OP_REF_CAST)))
			(then
				(return (call $value-type))
			)
		)
		;; Reference calls carry a heap type rather than a table selector.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_REF)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF)))
			(then
				(return (call $reference-type))
			)
		)
		;; Function and element-drop references retain forward names in their immediate fields.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_REF_FUNC)) (i32.eq (local.get $op) (i32.const M4_OP_ELEM_DROP)))
			(then
				(return (call $function-reference))
			)
		)
		;; Table initialization stores its independent table/element targets in the auxiliary arena.
		(if (i32.eq (local.get $op) (i32.const M4_OP_TABLE_INIT))
			(then
				(return (call $element-immediate))
			)
		)
		;; A null instruction retains its reference type for typed stack validation.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_NULL))
			(then
				(return (call $reference-type))
			)
		)
		;; Select collects zero or one result type across repeated result groups.
		(if (i32.eq (local.get $op) (i32.const M4_OP_SELECT))
			(then
				;; Stop at the first operand group, preserving its opening token.
				(block $done
					;; Empty result groups contribute no type; a second type is invalid.
					(loop $results
						(br_if $done (i32.ne (global.get $kind) (i32.const 1)))
						(local.set $start (global.get $tok))
						(call $next)
						;; Only result annotations belong to the immediate.
						(if (i32.eqz (call $is-word (i32.const 17) (i32.const 6)))
							(then
								(global.set $pos (local.get $start))
								(call $next)
								(br $done)
							)
						)
						(call $next)
						;; Consume types until the group closes, enforcing singleton arity.
						(block $group-done
							;; A nonempty annotation contains one supported value type.
							(loop $types
								(br_if $group-done (global.get $error))
								(br_if $group-done (i32.eq (global.get $kind) (i32.const 2)))
								;; A second type is invalid regardless of grouping.
								(if (local.get $value)
									(then
										(call $fail (i32.const M4_ERR_OPERAND_STACK))
										(br $group-done)
									)
								)
								(local.set $value (call $value-type))
								(br $types)
							)
						)
						(call $expect (i32.const 2))
						(br_if $done (global.get $error))
						(br $results)
					)
				)
				(return (local.get $value))
			)
		)
		;; Vector constants preserve their 128 bits in an auxiliary immediate record.
		(if (i32.eq (local.get $op) (i32.const M4_OP_V128_CONST))
			(then
				(return (call $vector-literal))
			)
		)
		;; SIMD lane indices and shuffle masks are parsed before folded operands.
		(if
			(i32.or
				(call $vector-lane-count (local.get $op))
				(i32.eq (local.get $op) (i32.const M4_OP_I8X16_SHUFFLE))
			)
			(then
				(return (call $vector-immediate (local.get $op)))
			)
		)
		;; Constants use the existing signed/unsigned i32 literal decoder.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_CONST))
			(then
				(return (call $integer))
			)
		)
		;; Float constants store their exact IEEE representation in the two immediate halves.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_F32_CONST)) (i32.eq (local.get $op) (i32.const M4_OP_F64_CONST)))
			(then
				(local.set $wide
					(call $float-literal
						(select (i32.const 3) (i32.const 4) (i32.eq (local.get $op) (i32.const M4_OP_F32_CONST)))
					)
				)
				(global.set $immediate-length (i32.wrap_i64 (i64.shr_u (local.get $wide) (i64.const 32))))
				(return (i32.wrap_i64 (local.get $wide)))
			)
		)
		;; Local accesses and direct calls carry an unsigned index or a named reference.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL))
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_LOCAL_GET))
					(i32.le_u (local.get $op) (i32.const M4_OP_CALL))
				)
			)
			(then
				;; Named calls retain their source span until module-wide resolution.
				(if (call $named)
					(then
						(local.set $value (global.get $tok))
						(local.set $length (global.get $len))
						(global.set $immediate-length (local.get $length))
						;; Local names resolve after inherited type parameters have shifted their final slots.
						(call $next)
						(return (local.get $value))
					)
				)
				(return (call $index))
			)
		)
		;; Indirect calls retain a complete deferred signature without consuming their folded arguments.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_INDIRECT)) (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_INDIRECT)))
			(then
				(return (call $indirect-signature))
			)
		)
		;; Wide constants preserve low and high halves in the instruction's existing immediate fields.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_CONST))
			(then
				(local.set $wide (call $integer64))
				(global.set $immediate-length (i32.wrap_i64 (i64.shr_u (local.get $wide) (i64.const 32))))
				(return (i32.wrap_i64 (local.get $wide)))
			)
		)
		;; Global immediates retain named references for module-wide resolution.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET)) (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_SET)))
			(then
				;; Preserve a global name span instead of confusing it with a local index.
				(if (call $named)
					(then
						(local.set $value (global.get $tok))
						(global.set $immediate-length (global.get $len))
						(call $next)
						(return (local.get $value))
					)
				)
				(return (call $index))
			)
		)
		;; Data instructions accept a deferred segment index or name, including forward references.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_INIT)) (i32.eq (local.get $op) (i32.const M4_OP_DATA_DROP)))
			(then
				;; Named data references retain their exact source span until module-wide resolution.
				(if (call $named)
					(then
						(local.set $value (global.get $tok))
						(global.set $immediate-length (global.get $len))
						(call $next)
						(return (local.get $value))
					)
				)
				(return (call $index))
			)
		)
		;; Table operations retain optional targets until module-wide validation.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_TABLE_SIZE)) (i32.eq (local.get $op) (i32.const M4_OP_TABLE_COPY)))
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_TABLE_GET))
					(i32.le_u (local.get $op) (i32.const M4_OP_TABLE_FILL))
				)
			)
			(then
				(return (call $table-immediate (local.get $op)))
			)
		)
		;; Loads and stores accept an optional unsigned offset followed by byte alignment.
		(if (call $memory-op (local.get $op))
			(then
				(local.set $value (call $memarg (local.get $op)))
				;; Lane memory operations append one bounded index after their memory attributes.
				(if (call $vector-memory-lanes (local.get $op))
					(then
						(global.set $immediate-length (call $index))
						;; The selected lane must belong to the operation's declared shape.
						(if
							(i32.ge_u (global.get $immediate-length) (call $vector-memory-lanes (local.get $op)))
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
							)
						)
					)
				)
				(return (local.get $value))
			)
		)
		;; Direct and conditional branches resolve their target label in the current control context.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR)) (i32.eq (local.get $op) (i32.const M4_OP_BR_IF)))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NULL)) (i32.eq (local.get $op) (i32.const M4_OP_BR_ON_NON_NULL)))
			)
			(then
				(return (call $label))
			)
		)
		;; Branch tables retain a contiguous vector of resolved depths, with the default entry last.
		(if (i32.eq (local.get $op) (i32.const M4_OP_BR_TABLE))
			(then
				(local.set $start (global.get $table-count))
				;; Stop collecting targets once the next token is not an identifier or unsigned index.
				(block $done
					;; Every target is resolved in the same enclosing label context.
					(loop $targets
						(br_if $done (global.get $error))
						(br_if $done (i32.ne (global.get $kind) (i32.const 3)))
						(br_if $done
							(i32.eqz
								(i32.or
									(call $named)
									(i32.and
										(i32.ge_u (i32.load8_u (global.get $tok)) (i32.const 48))
										(i32.le_u (i32.load8_u (global.get $tok)) (i32.const 57))
									)
								)
							)
						)
						;; Bound the shared branch-target arena before the host scratch region.
						(if (i32.ge_u (global.get $table-count) (i32.const M4_CAP_TABLE))
							(then
								(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
								(return (i32.const 0))
							)
						)
						(i32.store
							(i32.add (global.get $table-base) (i32.mul (global.get $table-count) (i32.const 4)))
							(call $label)
						)
						(global.set $table-count (i32.add (global.get $table-count) (i32.const 1)))
						(br $targets)
					)
				)
				(global.set $immediate-length (i32.sub (global.get $table-count) (local.get $start)))
				;; A branch table requires at least its default target.
				(if (i32.eqz (global.get $immediate-length))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
					)
				)
				(return (local.get $start))
			)
		)
		(i32.const 0)
	)

	;; Normalize both WAT syntaxes into explicit control markers and postorder operand instructions.
	;; Flat controls close with end; folded controls close with parentheses; folded if uses arm wrappers.
	(func $body
		(local $folded i32)
		(local $op i32)
		(local $value i32)
		(local $extra i32)
		(local $offset i32)
		(local $frame i32)
		(local $mode i32)
		(local $label i32)
		(local $length i32)

		(global.set $syntax-count (i32.const 0))
		;; Process tokens until the function closes or the first lexical/syntax error occurs.
		(loop $scan
			;; Stop immediately on a failure so a non-advancing token cannot cause an infinite parse loop.
			(if (global.get $error)
				(then
					(return)
				)
			)
			(local.set $frame (i32.const 0))
			(local.set $mode (i32.const -1))
			;; Inspect the innermost open expression or control before processing its next token.
			(if (global.get $syntax-count)
				(then
					(local.set $frame (call $syntax (i32.sub (global.get $syntax-count) (i32.const 1))))
					(local.set $mode (i32.load offset=16 (local.get $frame)))
				)
			)
			;; A closing parenthesis completes a folded expression/control, or the whole function.
			(if (i32.eq (global.get $kind) (i32.const 2))
				(then
					;; No open syntax means this parenthesis belongs to the function declaration.
					(if (i32.eqz (global.get $syntax-count))
						(then
							(return)
						)
					)
					(local.set $offset (global.get $tok))
					;; Ordinary folded instructions execute after their nested operands.
					(if (i32.eqz (local.get $mode))
						(then
							(call $emit
								(i32.load (local.get $frame))
								(i32.load offset=4 (local.get $frame))
								(i32.load offset=8 (local.get $frame))
								(i32.load offset=12 (local.get $frame))
							)
						)
					)
					;; Folded block/loop and completed if arms end their control scope here.
					(if
						(i32.or
							(i32.eq (local.get $mode) (i32.const 2))
							(i32.or (i32.eq (local.get $mode) (i32.const 5)) (i32.eq (local.get $mode) (i32.const 7)))
						)
						(then
							(call $close-control (local.get $frame) (local.get $offset))
						)
					)
					;; Flat controls or an if without a completed then arm cannot close by parenthesis.
					(if
						(i32.or
							(i32.eq (local.get $mode) (i32.const 1))
							(i32.or
								(i32.eq (local.get $mode) (i32.const 3))
								(i32.or (i32.eq (local.get $mode) (i32.const 4)) (i32.eq (local.get $mode) (i32.const 6)))
							)
						)
						(then
							(call $fail (i32.const M4_ERR_SYNTAX))
							(return)
						)
					)
					(global.set $syntax-count (i32.sub (global.get $syntax-count) (i32.const 1)))
					;; Closing an arm wrapper moves its parent if into the corresponding completed phase.
					(if (i32.ge_u (local.get $mode) (i32.const 8))
						(then
							(i32.store offset=16
								(call $syntax (i32.sub (global.get $syntax-count) (i32.const 1)))
								(i32.sub (i32.mul (local.get $mode) (i32.const 2)) (i32.const 11))
							)
						)
					)
					(call $next)
					(br $scan)
				)
			)
			(local.set $folded (i32.eq (global.get $kind) (i32.const 1)))
			;; Opening parentheses introduce a folded instruction or a folded-if arm wrapper.
			(if (local.get $folded)
				(then
					(call $next)
				)
			)
			;; An instruction position must contain an opcode atom, including after an opening delimiter.
			(if (i32.ne (global.get $kind) (i32.const 3))
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			(local.set $offset (global.get $tok))
			(local.set $op (call $opcode))
			;; Unknown opcodes are unsupported rather than silently skipped.
			(if (i32.eqz (local.get $op))
				(then
					(call $fail (i32.const M4_ERR_UNSUPPORTED))
					(return)
				)
			)
			;; Ordinary folded operands and folded-if conditions require parenthesized subexpressions.
			(if
				(i32.and
					(i32.eqz (local.get $folded))
					(i32.or (i32.eqz (local.get $mode)) (i32.eq (local.get $mode) (i32.const 3)))
				)
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			;; A completed folded then arm allows only else; a completed else arm allows only closure.
			(if
				(i32.or
					(i32.eq (local.get $mode) (i32.const 7))
					(i32.and (i32.eq (local.get $mode) (i32.const 5)) (i32.ne (local.get $op) (i32.const M4_OP_ELSE)))
				)
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			(call $next)
			;; Folded then activates its pending if after all condition operands have been emitted.
			(if (i32.eq (local.get $op) (i32.const M4_OP_THEN))
				(then
					;; Then wrappers belong only to a pending folded if.
					(if (i32.eqz (i32.and (local.get $folded) (i32.eq (local.get $mode) (i32.const 3))))
						(then
							(call $fail (i32.const M4_ERR_SYNTAX))
							(return)
						)
					)
					(call $start-control (local.get $frame))
					(i32.store offset=16 (local.get $frame) (i32.const 4))
					(call $push-syntax
						(i32.const M4_OP_THEN)
						(i32.const 0)
						(local.get $offset)
						(i32.const 0)
						(i32.const 8)
						(i32.const 0)
						(i32.const 0)
					)
					(br $scan)
				)
			)
			;; Else either opens a folded arm or separates the two arms of a flat if.
			(if (i32.eq (local.get $op) (i32.const M4_OP_ELSE))
				(then
					;; Folded else requires a completed then wrapper in the same folded if.
					(if (local.get $folded)
						(then
							;; Other syntactic parents cannot own an else wrapper.
							(if (i32.ne (local.get $mode) (i32.const 5))
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
									(return)
								)
							)
							(call $else-control (local.get $frame) (local.get $offset))
							(i32.store offset=16 (local.get $frame) (i32.const 6))
							(call $push-syntax
								(i32.const M4_OP_ELSE)
								(i32.const 0)
								(local.get $offset)
								(i32.const 0)
								(i32.const 9)
								(i32.const 0)
								(i32.const 0)
							)
						)
						;; Flat else must match the innermost open flat if, including any repeated label.
						(else
							;; An else cannot cross another block or expression to find its if.
							(if
								(i32.eqz
									(i32.and
										(i32.eq (local.get $mode) (i32.const 1))
										(i32.eq (i32.load (local.get $frame)) (i32.const 39))
									)
								)
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
									(return)
								)
							)
							(call $repeat-label (local.get $frame))
							(call $else-control (local.get $frame) (local.get $offset))
						)
					)
					(br $scan)
				)
			)
			;; Flat end closes exactly one flat control frame; folded controls use parentheses instead.
			(if (i32.eq (local.get $op) (i32.const M4_OP_END))
				(then
					;; End markers cannot close ordinary expressions or folded scopes.
					(if (i32.or (local.get $folded) (i32.ne (local.get $mode) (i32.const 1)))
						(then
							(call $fail (i32.const M4_ERR_SYNTAX))
							(return)
						)
					)
					(call $repeat-label (local.get $frame))
					(call $close-control (local.get $frame) (local.get $offset))
					(global.set $syntax-count (i32.sub (global.get $syntax-count) (i32.const 1)))
					(br $scan)
				)
			)
			;; Block, loop and if introduce a new label scope and an optional result signature.
			(if (call $control-op (local.get $op))
				(then
					(local.set $label (i32.const 0))
					(local.set $length (i32.const 0))
					;; Preserve an optional label for named branches and matching flat closing markers.
					(if (call $named)
						(then
							(local.set $label (global.get $tok))
							(local.set $length (global.get $len))
							(call $next)
						)
					)
					(local.set $value (call $block-result))
					(local.set $extra (i32.const 0))
					;; Try-table catches target outer labels before the new try label enters scope.
					(if (i32.eq (local.get $op) (i32.const M4_OP_TRY_TABLE))
						(then
							(local.set $extra (call $parse-try-handlers))
						)
					)
					(local.set $mode (i32.const 1))
					;; Folded blocks/loops close by parentheses; folded if must first parse its condition.
					(if (local.get $folded)
						(then
							(local.set $mode (i32.const 2))
							;; Only folded if defers its control entry until the then wrapper.
							(if (i32.eq (local.get $op) (i32.const M4_OP_IF))
								(then
									(local.set $mode (i32.const 3))
								)
							)
						)
					)
					(call $push-syntax
						(local.get $op)
						(i32.const -1)
						(local.get $offset)
						(local.get $value)
						(local.get $mode)
						(local.get $label)
						(local.get $length)
					)
					(i32.store offset=28
						(call $syntax (i32.sub (global.get $syntax-count) (i32.const 1)))
						(local.get $extra)
					)
					;; Emit all controls except a pending folded-if condition.
					(if (i32.and (i32.eqz (global.get $error)) (i32.ne (local.get $mode) (i32.const 3)))
						(then
							(call $start-control (call $syntax (i32.sub (global.get $syntax-count) (i32.const 1))))
						)
					)
					(br $scan)
				)
			)
			(local.set $value (call $instruction-immediate (local.get $op)))
			(local.set $extra (global.get $immediate-length))
			;; Folded ordinary instructions wait for their operands; flat instructions append immediately.
			(if (local.get $folded)
				(then
					(call $push-syntax
						(local.get $op)
						(local.get $value)
						(local.get $offset)
						(local.get $extra)
						(i32.const 0)
						(i32.const 0)
						(i32.const 0)
					)
				)
				;; Flat code already has its operands before the opcode in execution order.
				(else
					(call $emit (local.get $op) (local.get $value) (local.get $offset) (local.get $extra))
				)
			)
			(br $scan)
		)
	)
