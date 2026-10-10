	;; Recognize exception grammar keywords without expanding the reserved keyword buffer.
	(func $is-exception-word
		(param $word i32)
		(result i32)

		;; Match the complete tag keyword after checking its selector.
		(if (i32.eq (local.get $word) (i32.const 0))
			(then
				(return
					(i32.and
						(i32.and
							(i32.and
								(i32.eq (global.get $len) (i32.const 3))
								(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 116))
							)
							(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 97))
						)
						(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 103))
					)
				)
			)
		)
		;; Match the complete catch keyword after checking its selector.
		(if (i32.eq (local.get $word) (i32.const 1))
			(then
				(return
					(i32.and
						(i32.and
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 5))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 99))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 97))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 116))
							)
							(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 99))
						)
						(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 104))
					)
				)
			)
		)
		;; Match the complete catch_ref keyword after checking its selector.
		(if (i32.eq (local.get $word) (i32.const 2))
			(then
				(return
					(i32.and
						(i32.and
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.eq (global.get $len) (i32.const 9))
														(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 99))
													)
													(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 97))
												)
												(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 116))
											)
											(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 99))
										)
										(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 104))
									)
									(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 95))
								)
								(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 114))
							)
							(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 101))
						)
						(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 102))
					)
				)
			)
		)
		;; Match the complete catch_all keyword after checking its selector.
		(if (i32.eq (local.get $word) (i32.const 3))
			(then
				(return
					(i32.and
						(i32.and
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.eq (global.get $len) (i32.const 9))
														(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 99))
													)
													(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 97))
												)
												(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 116))
											)
											(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 99))
										)
										(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 104))
									)
									(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 95))
								)
								(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 97))
							)
							(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 108))
						)
						(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 108))
					)
				)
			)
		)
		;; Match the complete catch_all_ref keyword after checking its selector.
		(if (i32.eq (local.get $word) (i32.const 4))
			(then
				(return
					(i32.and
						(i32.and
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.and
																(i32.and
																	(i32.and
																		(i32.eq (global.get $len) (i32.const 13))
																		(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 99))
																	)
																	(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 97))
																)
																(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 116))
															)
															(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 99))
														)
														(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 104))
													)
													(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 95))
												)
												(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 97))
											)
											(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 108))
										)
										(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 108))
									)
									(i32.eq (i32.load8_u offset=9 (global.get $tok)) (i32.const 95))
								)
								(i32.eq (i32.load8_u offset=10 (global.get $tok)) (i32.const 114))
							)
							(i32.eq (i32.load8_u offset=11 (global.get $tok)) (i32.const 101))
						)
						(i32.eq (i32.load8_u offset=12 (global.get $tok)) (i32.const 102))
					)
				)
			)
		)
		(i32.const 0)
	)

	;; Locate a tag descriptor containing its name, deferred signature and bound runtime identity.
	(func $tag-record (export "tag_info")
		(param $index i32)
		(result i32)

		(i32.add (global.get $tag-base) (i32.mul (local.get $index) (i32.const 64)))
	)

	;; Find a tag identifier in its independent source-order namespace.
	(func $find-tag
		(param $name i32)
		(param $length i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; A missing identifier returns minus one after checking every tag declaration.
		(block $done
			;; Names compare by complete decoded identifier byte strings.
			(loop $tags
				(br_if $done (i32.eq (local.get $i) (global.get $tag-count)))
				(local.set $record (call $tag-record (local.get $i)))
				;; Equal lengths and bytes identify a tag regardless of other resource names.
				(if
					;; Compare bytes only after the complete span/prefix guard succeeds.
					(if (result i32)
						(i32.eq (local.get $length) (i32.load offset=4 (local.get $record)))
						(then
							(call $equal (local.get $name) (i32.load (local.get $record)) (local.get $length))
						)
						;; An incompatible span cannot match this name or prefix.
						(else (i32.const 0))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $tags)
			)
		)
		(i32.const -1)
	)

	;; Resolve a numeric or named tag reference against all parsed declarations.
	(func $tag-target
		(param $value i32)
		(param $length i32)
		(param $source i32)
		(result i32)

		;; Source-backed names resolve only after the complete tag namespace is known.
		(if (local.get $length)
			(then
				(local.set $value (call $find-tag (local.get $value) (local.get $length)))
			)
		)
		;; Missing or out-of-range tags are validation reference errors.
		(if (i32.ge_u (local.get $value) (global.get $tag-count))
			(then
				(global.set $tok (local.get $source))
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
			)
		)
		(local.get $value)
	)

	;; Parse a tag's name, inline exports/import and deferred function-shaped parameter signature.
	(func $parse-tag
		(local $index i32)
		(local $record i32)

		(local.set $index (global.get $tag-count))
		;; Bound tag descriptors independently from the function namespace.
		(if (i32.ge_u (local.get $index) (global.get $tag-limit))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(local.set $record (call $tag-record (local.get $index)))
		(call $zero-bytes (local.get $record) (i32.const 64))
		(i32.store offset=20 (local.get $record) (global.get $tok))
		(call $next)
		;; A named tag cannot redeclare an existing identifier in its own namespace.
		(if (call $named)
			(then
				;; Duplicate names fail before allocating the declaration index.
				(if (i32.ne (call $find-tag (global.get $tok) (global.get $len)) (i32.const -1))
					(then
						(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
					)
				)
				(i32.store (local.get $record) (global.get $tok))
				(i32.store offset=4 (local.get $record) (global.get $len))
				(call $next)
			)
		)
		(global.set $tag-count (i32.add (local.get $index) (i32.const 1)))
		(call $resource-exports (i32.const 4) (local.get $index))
		(i32.store offset=12 (local.get $record) (global.get $parsing-import))
		(i32.store offset=8 (local.get $record) (call $indirect-signature))
		(call $expect (i32.const 2))
		(call $finish-resource-declaration (i32.const 4) (local.get $index))
	)

	;; Compare complete ordered function signatures for canonical anonymous tag types.
	(func $signature-equal
		(param $a i32)
		(param $b i32)
		(result i32)
		(local $i i32)

		;; Counts and result shapes must agree before reading parameter slots.
		(if
			(i32.or
				(i32.ne (i32.load offset=8 (local.get $a)) (i32.load offset=8 (local.get $b)))
				(i32.eqz
					(call $shape-equal
						(i32.load offset=12 (local.get $a))
						(i32.load offset=12 (local.get $b))
					)
				)
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Compare all ordered parameters with full canonical reference equality.
		(block $done
			;; Finish after the last parameter has matched.
			(loop $params
				(br_if $done (i32.eq (local.get $i) (i32.load offset=8 (local.get $a))))
				;; A differing concrete or numeric parameter prevents canonical reuse.
				(if
					(i32.eqz
						(call $type-equal
							(i32.load offset=32 (i32.add (local.get $a) (i32.mul (local.get $i) (i32.const 4))))
							(i32.load offset=32 (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 4))))
						)
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $params)
			)
		)
		(i32.const 1)
	)

	;; Complete tag type uses, reject results and intern anonymous parameter signatures.
	(func $resolve-tags
		(local $i i32)
		(local $j i32)
		(local $record i32)
		(local $signature i32)

		;; Visit every tag once after the common signature resolver has applied explicit type uses.
		(block $done
			;; Explicit tags retain recursive identity; inline tags acquire canonical singleton function types.
			(loop $tags
				(br_if $done (i32.eq (local.get $i) (global.get $tag-count)))
				(local.set $record (call $tag-record (local.get $i)))
				(local.set $signature (call $signature (i32.load offset=8 (local.get $record))))
				;; Exception payloads cannot contain a function result vector.
				(if (i32.load offset=12 (local.get $signature))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				;; Explicit type uses retain their declared recursive group member identity.
				(if (i32.and (i32.load offset=28 (local.get $signature)) (i32.const 1))
					(then
						(local.set $j
							(call $type-target
								(i32.load offset=16 (local.get $signature))
								(i32.load offset=20 (local.get $signature))
								(i32.load offset=24 (local.get $signature))
							)
						)
					)
					;; Inline signatures search canonical singleton function declarations.
					(else
						(local.set $j (i32.const 0))
						;; Stop at a matching signature or the namespace end.
						(block $found
							;; Previously interned inline types participate in later tag deduplication.
							(loop $types
								(br_if $found (i32.eq (local.get $j) (global.get $signature-count)))
								(br_if $found
									(i32.and
										(call $implicit-heap-type (local.get $j))
										(call $signature-equal (local.get $signature) (call $signature (local.get $j)))
									)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $types)
							)
						)
						;; A missing singleton signature appends an anonymous canonical type.
						(if (i32.eq (local.get $j) (global.get $signature-count))
							(then
								;; Bound the type namespace before copying the parameter vector.
								(if (i32.ge_u (local.get $j) (global.get $type-limit))
									(then
										(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
										(return)
									)
								)
								(call $initialize-heap-type (local.get $j))
								(memory.copy (call $signature (local.get $j)) (local.get $signature) (global.get $signature-bytes))
								(global.set $signature-count (i32.add (local.get $j) (i32.const 1)))
							)
						)
					)
				)
				(i32.store offset=24 (local.get $record) (local.get $j))
				;; Every explicit tag type must describe a function, including empty signatures.
				(if (i32.load (call $heap-record (local.get $j)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $tags)
			)
		)
	)

	;; Expose a tag's complete canonical type to trusted import linking.
	(func (export "tag_type")
		(param $index i32)
		(result i32)

		(call $intern-reference-type
			(i32.load offset=24 (call $tag-record (local.get $index)))
			(i32.const 0)
			(global.get $tok)
			(i32.const 1)
		)
	)

	;; Report the declared tag count for host assignment of instance-specific tag identities.
	(func (export "tag_count")
		(result i32)

		(global.get $tag-count)
	)

	;; Bind a host-assigned tag identity shared by imported aliases and independently instantiated definitions.
	(func (export "bind_tag")
		(param $index i32)
		(param $identity i32)

		(i32.store offset=16 (call $tag-record (local.get $index)) (local.get $identity))
	)

	;; Recognize structured control entries, including exception-aware try-table regions.
	(func $control-op
		(param $op i32)
		(result i32)

		(i32.or
			(i32.eq (local.get $op) (i32.const M4_OP_TRY_TABLE))
			(i32.and
				(i32.ge_u (local.get $op) (i32.const M4_OP_BLOCK))
				(i32.le_u (local.get $op) (i32.const M4_OP_IF))
			)
		)
	)

	;; Parse the ordered catch clauses of a try-table without entering its own label scope.
	(func $parse-try-handlers
		(result i32)
		(local $header i32)
		(local $node i32)
		(local $last i32)
		(local $open i32)
		(local $kind i32)

		(local.set $header (call $new-memory-immediate))
		;; The first body expression terminates the handler list and remains available to the instruction parser.
		(block $done
			;; Clauses retain their source order because the first matching clause wins.
			(loop $clauses
				(br_if $done (global.get $error))
				(br_if $done (i32.ne (global.get $kind) (i32.const 1)))
				(local.set $open (global.get $tok))
				(call $next)
				(local.set $kind (i32.const 1))
				;; Probe the four clause spellings without changing tokens during matching.
				(block $matched
					;; Selector five marks an ordinary body expression rather than a catch clause.
					(loop $names
						(br_if $matched (i32.eq (local.get $kind) (i32.const 5)))
						(br_if $matched (call $is-exception-word (local.get $kind)))
						(local.set $kind (i32.add (local.get $kind) (i32.const 1)))
						(br $names)
					)
				)
				;; Restore an ordinary expression's opening delimiter before finishing header parsing.
				(if (i32.eq (local.get $kind) (i32.const 5))
					(then
						(global.set $pos (local.get $open))
						(call $next)
						(br $done)
					)
				)
				(local.set $node (call $new-memory-immediate))
				(i32.store (local.get $node) (local.get $kind))
				(i32.store offset=12 (local.get $node) (global.get $tok))
				(call $next)
				;; Typed clauses name a tag before their outer target label.
				(if (i32.le_u (local.get $kind) (i32.const 2))
					(then
						(i32.store offset=4 (local.get $node) (call $function-reference))
						(i32.store offset=8 (local.get $node) (global.get $immediate-length))
					)
				)
				(i32.store offset=16 (local.get $node) (call $label))
				(call $expect (i32.const 2))
				;; Append to the linked list while retaining the first clause in the header.
				(if (local.get $last)
					(then
						(i32.store offset=20 (local.get $last) (local.get $node))
					)
					;; The first clause initializes the header's list pointer.
					(else
						(i32.store (local.get $header) (local.get $node))
					)
				)
				(local.set $last (local.get $node))
				(br $clauses)
			)
		)
		(local.get $header)
	)

	;; Validate catch payload vectors against their enclosing branch target signatures.
	(func $validate-try-handlers
		(param $header i32)
		(local $node i32)
		(local $kind i32)
		(local $tag i32)
		(local $signature i32)
		(local $label i32)
		(local $count i32)
		(local $i i32)

		(local.set $node (i32.load (local.get $header)))
		;; Finish after all catch clauses have been checked, including unreachable handlers.
		(block $done
			;; Typed catches validate the complete payload; catch-all clauses transfer only an optional exnref.
			(loop $clauses
				(br_if $done (i32.eqz (local.get $node)))
				(local.set $kind (i32.load (local.get $node)))
				(local.set $count (i32.const 0))
				;; Typed clauses resolve their tag against the completed namespace.
				(if (i32.le_u (local.get $kind) (i32.const 2))
					(then
						(local.set $tag
							(call $tag-target
								(i32.load offset=4 (local.get $node))
								(i32.load offset=8 (local.get $node))
								(i32.load offset=12 (local.get $node))
							)
						)
						(i32.store offset=4 (local.get $node) (local.get $tag))
						(i32.store offset=8 (local.get $node) (i32.const 0))
						(local.set $signature
							(call $signature (i32.load offset=8 (call $tag-record (local.get $tag))))
						)
						(local.set $count (i32.load offset=8 (local.get $signature)))
					)
				)
				(local.set $label (call $label-arity (i32.load offset=16 (local.get $node))))
				;; Reference catches append a non-null exception reference after any typed payload.
				(if
					(i32.ne
						(call $shape-count (local.get $label))
						(i32.add
							(local.get $count)
							(i32.or (i32.eq (local.get $kind) (i32.const 2)) (i32.eq (local.get $kind) (i32.const 4)))
						)
					)
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(local.set $i (i32.const 0))
				;; Check ordered payload types without consuming ordinary body operands.
				(block $types-done
					;; Each target slot must accept the tag's declared payload type covariantly.
					(loop $types
						(br_if $types-done (i32.eq (local.get $i) (local.get $count)))
						;; A payload mismatch is a validation error even when the tag is never thrown.
						(if
							(i32.eqz
								(call $type-compatible
									(i32.load offset=32
										(i32.add (local.get $signature) (i32.mul (local.get $i) (i32.const 4)))
									)
									(call $shape-type (local.get $label) (local.get $i))
								)
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $types)
					)
				)
				;; A reference clause's final branch slot must accept the exception hierarchy.
				(if
					(i32.or (i32.eq (local.get $kind) (i32.const 2)) (i32.eq (local.get $kind) (i32.const 4)))
					(then
						;; Newly caught exceptions are non-null values.
						(if
							(i32.eqz
								(call $type-compatible
									(i32.const 33)
									(call $shape-type (local.get $label) (local.get $count))
								)
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
					)
				)
				(local.set $node (i32.load offset=20 (local.get $node)))
				(br $clauses)
			)
		)
	)

	;; Validate a throw's ordered tag payload or the exception reference used by throw-ref.
	(func $validate-throw
		(param $op i32)
		(param $immediate i32)
		(local $tag i32)
		(local $signature i32)
		(local $i i32)

		;; Throw-ref consumes a nullable exception reference and may trap dynamically on null.
		(if (i32.eq (local.get $op) (i32.const M4_OP_THROW_REF))
			(then
				(drop (call $validation-pop (i32.const 32)))
				(return)
			)
		)
		(local.set $tag
			(call $tag-target
				(i32.load (local.get $immediate))
				(i32.load offset=4 (local.get $immediate))
				(i32.load offset=8 (local.get $immediate))
			)
		)
		(i32.store (local.get $immediate) (local.get $tag))
		(i32.store offset=4 (local.get $immediate) (i32.const 0))
		;; Invalid tag references must not become signature arena pointers.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $signature
			(call $signature (i32.load offset=8 (call $tag-record (local.get $tag))))
		)
		(local.set $i (i32.load offset=8 (local.get $signature)))
		;; Payload operands appear in declaration order and are popped in reverse.
		(block $done
			;; Unreachable payloads remain polymorphic under the ordinary validation rules.
			(loop $params
				(br_if $done (i32.eqz (local.get $i)))
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				(drop
					(call $validation-pop
						(i32.load offset=32
							(i32.add (local.get $signature) (i32.mul (local.get $i) (i32.const 4)))
						)
					)
				)
				(br $params)
			)
		)
	)

	;; Decode an exception handle into its private object containing identity and raw payload slots.
	(func $exception-object
		(param $value i64)
		(result i32)

		(i32.add
			(global.get $gc-object-base)
			(i32.and (i32.wrap_i64 (local.get $value)) (i32.const 268435455))
		)
	)

	;; Allocate payloads plus a variable reference bitmap, retaining the original small-object layout.
	(func $exception-slot-count
		(param $count i32)
		(result i32)
		(local $masks i32)

		(local.set $masks (i32.shr_u (i32.add (local.get $count) (i32.const 127)) (i32.const 7)))
		(i32.add (i32.add (local.get $count) (i32.const 1))
			(select (local.get $masks) (i32.const 2) (i32.gt_u (local.get $masks) (i32.const 2))))
	)

	;; Capture a fresh thrown tag payload in reverse operand order without losing vector high halves.
	(func $create-exception
		(param $tag i32)
		(result i64)
		(local $signature i32)
		(local $count i32)
		(local $object i32)
		(local $i i32)
		(local $value i64)

		(local.set $signature
			(call $signature (i32.load offset=8 (call $tag-record (local.get $tag))))
		)
		(local.set $count (i32.load offset=8 (local.get $signature)))
		(local.set $object
			(call $gc-allocate (i32.const -1) (call $exception-slot-count (local.get $count)) (i32.const 1))
		)
		;; A failed allocation must not corrupt interpreter state through address zero.
		(if (global.get $error) (then (return (i64.const 0))))
		(i32.store offset=4 (local.get $object) (i32.add (local.get $count) (i32.const 1)))
		(i32.store offset=8 (local.get $object) (local.get $tag))
		(i64.store
			(call $gc-slot (local.get $object) (i32.const 0))
			(i64.extend_i32_u (i32.load offset=16 (call $tag-record (local.get $tag))))
		)
		(local.set $i (local.get $count))
		;; Copy every payload slot before unwinding any call or control frame.
		(block $done
			;; Reverse stack consumption preserves the declared payload order in the exception object.
			(loop $params
				(br_if $done (i32.eqz (local.get $i)))
				(local.set $value (call $gc-pop))
				;; Numeric payloads with reference-like bits must never keep objects alive.
				(if (call $is-reference (i32.load offset=32
					(i32.add (local.get $signature) (i32.mul (i32.sub (local.get $i) (i32.const 1)) (i32.const 4)))))
					(then (call $gc-exception-mask (local.get $object) (i32.sub (local.get $i) (i32.const 1))))
				)
				(i64.store (call $gc-slot (local.get $object) (local.get $i)) (local.get $value))
				(i64.store offset=8
					(call $gc-slot (local.get $object) (local.get $i))
					(global.get $gc-high)
				)
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				(br $params)
			)
		)
		(i64.extend_i32_u
			(i32.or (i32.const 268435456) (i32.sub (local.get $object) (global.get $gc-object-base)))
		)
	)

	;; Search active handlers across calls, transfer a matching payload, and return the surviving call depth.
	(func $dispatch-exception
		(param $frame i32)
		(param $calls i32)
		(result i32)
		(local $i i32)
		(local $control i32)
		(local $node i32)
		(local $kind i32)
		(local $object i32)
		(local $count i32)
		(local $j i32)
		(local $target i32)

		(local.set $object (call $exception-object (global.get $exception-value)))
		(local.set $i (global.get $control-count))
		;; An uncaught exception reaches the host after every active try region has been examined.
		(block $uncaught
			;; Inner regions and earlier clauses take precedence over outer handlers.
			(loop $controls
				(br_if $uncaught (i32.le_u (local.get $i) (global.get $reentry-control)))
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				(local.set $control (call $control (local.get $i)))
				;; Ordinary blocks and function roots cannot catch an exception.
				(if (i32.eq (i32.load (local.get $control)) (i32.const M4_OP_TRY_TABLE))
					(then
						(local.set $node
							(i32.load (i32.load offset=24 (call $metadata (i32.load offset=4 (local.get $control)))))
						)
						;; Exhausting this clause list resumes the outer control search.
						(block $next-control
							;; Catch-all clauses match every identity; typed catches compare bound tag identities.
							(loop $clauses
								(br_if $next-control (i32.eqz (local.get $node)))
								(local.set $kind (i32.load (local.get $node)))
								;; A matching clause transfers its payload to an enclosing branch target.
								(if
									(i32.or
										(i32.ge_u (local.get $kind) (i32.const 3))
										(i64.eq
											(i64.load (call $gc-slot (local.get $object) (i32.const 0)))
											(i64.extend_i32_u
												(i32.load offset=16 (call $tag-record (i32.load offset=4 (local.get $node))))
											)
										)
									)
									(then
										;; Unwind call frames until this handler belongs to the surviving function.
										(block $owner-found
											;; A caller's root control index precedes every region in that caller.
											(loop $calls
												(br_if $owner-found
													(i32.le_u (i32.load (i32.add (local.get $frame) (global.get $call-root-offset))) (local.get $i))
												)
												(local.set $calls (i32.sub (local.get $calls) (i32.const 1)))
												(local.set $frame
													(i32.add
														(global.get $call-base)
														(i32.mul (i32.sub (local.get $calls) (i32.const 1)) (global.get $call-bytes))
													)
												)
												(br $calls)
											)
										)
										(global.set $sp (i32.load offset=12 (local.get $control)))
										(local.set $count
											(select
												(i32.sub (i32.load offset=4 (local.get $object)) (i32.const 1))
												(i32.const 0)
												(i32.le_u (local.get $kind) (i32.const 2))
											)
										)
										(local.set $j (i32.const 0))
										;; Typed catches publish complete payload slots before their optional exnref.
										(block $copied
											;; Both vector halves are restored to the surviving operand stack.
											(loop $payload
												(br_if $copied (i32.eq (local.get $j) (local.get $count)))
												(call $runtime-value
													(i64.load (call $gc-slot (local.get $object) (i32.add (local.get $j) (i32.const 1))))
												)
												(i64.store
													(i32.add
														(global.get $stack-high-base)
														(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
													)
													(i64.load offset=8
														(call $gc-slot (local.get $object) (i32.add (local.get $j) (i32.const 1)))
													)
												)
												(local.set $j (i32.add (local.get $j) (i32.const 1)))
												(br $payload)
											)
										)
										;; Reference catch variants append the original non-null exception handle.
										(if
											(i32.or (i32.eq (local.get $kind) (i32.const 2)) (i32.eq (local.get $kind) (i32.const 4)))
											(then
												(call $runtime-value (global.get $exception-value))
											)
										)
										(local.set $target
											(i32.sub (i32.sub (local.get $i) (i32.const 1)) (i32.load offset=16 (local.get $node)))
										)
										(call $runtime-jump (local.get $target) (local.get $frame))
										(return (local.get $calls))
									)
								)
								(local.set $node (i32.load offset=20 (local.get $node)))
								(br $clauses)
							)
						)
					)
				)
				(br $controls)
			)
		)
		(call $fail (i32.const M4_ERR_UNCAUGHT_EXCEPTION))
		(i32.const 0)
	)

	;; Report the uncaught exception reference for host propagation and cross-instance rethrow.
	(func (export "exception_reference")
		(result i64)

		(global.get $exception-value)
	)

	;; Expose an exception object's immutable identity and raw payload to trusted host propagation.
	(func (export "exception_info")
		(param $value i64)
		(result i32)

		(call $exception-object (local.get $value))
	)

	;; Preserve the original two-word bitmap ABI for existing low-level hosts.
	(func (export "import_exception")
		(param $identity i32) (param $count i32) (param $args i32)
		(param $refs-low i64) (param $refs-high i64) (result i64)

		(call $import-exception (local.get $identity) (local.get $count) (local.get $args)
			(i32.const 0) (local.get $refs-low) (local.get $refs-high))
	)

	;; Import the complete variable-width bitmap for larger public exception payloads.
	(func (export "import_exception_bits")
		(param $identity i32) (param $count i32) (param $args i32) (param $refs i32) (result i64)

		(call $import-exception (local.get $identity) (local.get $count) (local.get $args)
			(local.get $refs) (i64.const 0) (i64.const 0))
	)

	;; Copy host payload bits and exact reference positions before resuming guest dispatch.
	(func $import-exception
		(param $identity i32) (param $count i32) (param $args i32) (param $refs i32)
		(param $refs-low i64) (param $refs-high i64) (result i64)
		(local $object i32)
		(local $i i32)
		(local $tag i32)

		(local.set $object
			(call $gc-allocate (i32.const -1) (call $exception-slot-count (local.get $count)) (i32.const 1))
		)
		(local.set $tag (i32.const -1))
		;; Find a local alias of the received tag identity for subsequent host payload diagnostics.
		(block $tag-done
			;; Unknown identities can still be caught by catch-all clauses.
			(loop $tags
				(br_if $tag-done (i32.eq (local.get $i) (global.get $tag-count)))
				;; The first identity alias has the same payload signature as all later aliases.
				(if
					(i32.eq (i32.load offset=16 (call $tag-record (local.get $i))) (local.get $identity))
					(then
						(local.set $tag (local.get $i))
						(br $tag-done)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $tags)
			)
		)
		;; A failed allocation must not corrupt interpreter state through address zero.
		(if (global.get $error) (then (return (i64.const 0))))
		(i32.store offset=4 (local.get $object) (i32.add (local.get $count) (i32.const 1)))
		(i32.store offset=8 (local.get $object) (local.get $tag))
		(i64.store
			(call $gc-slot (local.get $object) (i32.const 0))
			(i64.extend_i32_u (local.get $identity))
		)
		;; The public adapter supplies every bitmap word; legacy callers supply exactly two.
		(if (local.get $refs)
			(then
				(memory.copy (call $gc-slot (local.get $object) (i32.add (local.get $count) (i32.const 1)))
					(local.get $refs) (i32.shl (i32.shr_u (i32.add (local.get $count) (i32.const 63)) (i32.const 6)) (i32.const 3)))
			)
			;; Original payloads retain their two reference words and all upper slots stay zero.
			(else
				(i64.store (call $gc-slot (local.get $object) (i32.add (local.get $count) (i32.const 1))) (local.get $refs-low))
				(i64.store offset=8 (call $gc-slot (local.get $object) (i32.add (local.get $count) (i32.const 1))) (local.get $refs-high))
			)
		)
		(local.set $i (i32.const 0))
		;; Copy canonical raw argument slots out of transient host scratch before dispatch resumes.
		(block $done
			;; Each payload preserves both vector halves and any reference handle.
			(loop $payload
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(i64.store
					(call $gc-slot (local.get $object) (i32.add (local.get $i) (i32.const 1)))
					(i64.load (i32.add (local.get $args) (i32.mul (local.get $i) (i32.const 8))))
				)
				(i64.store offset=8
					(call $gc-slot (local.get $object) (i32.add (local.get $i) (i32.const 1)))
					(i64.load
						(i32.add (global.get $argument-high-base) (i32.mul (local.get $i) (i32.const 8)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $payload)
			)
		)
		(i64.extend_i32_u
			(i32.or (i32.const 268435456) (i32.sub (local.get $object) (global.get $gc-object-base)))
		)
	)

	;; Resume a suspended imported call by propagating a guest exception through its saved control frames.
	(func (export "resume_exception")
		(param $value i64)
		(result i64)

		(global.set $error (i32.const M4_ERR_SUCCESS))
		;; Exceptions can resume only a pending import, using the same protected continuation as normal results.
		(if (i32.lt_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const M4_ERR_INVALID_RESUME))
				(return (i64.const 0))
			)
		)
		(global.set $pending-import (i32.const -1))
		(global.set $exception-value (local.get $value))
		;; A directly exported import has no enclosing guest handler to search.
		(if (i32.eqz (global.get $saved-calls))
			(then
				(call $fail (i32.const M4_ERR_UNCAUGHT_EXCEPTION))
				(return (call $finish-start (i64.const 0)))
			)
		)
		(global.set $exception-pending (i32.const 1))
		(global.set $resuming (i32.const 1))
		(call $finish-start (call $run (i32.const 0) (i32.const 0)))
	)
