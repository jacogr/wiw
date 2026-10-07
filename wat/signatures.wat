	;; Locate a bounded 544-byte signature: name, parameter count/result shape, reference metadata, 128 type slots.
	(func $signature
		(param $index i32)
		(result i32)

		(i32.add (global.get $signature-base) (i32.mul (local.get $index) (i32.const 544)))
	)

	;; Locate deferred function type metadata; offset 20 retains a completed non-null reference type.
	(func $function-type
		(param $index i32)
		(result i32)

		(i32.add (global.get $function-type-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Find a declared type by its complete identifier; anonymous indirect signatures are outside this namespace.
	(func $find-type
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $i i32)
		(local $s i32)

		;; Named type uses share a lazily extended index once the namespace is large enough.
		(if (i32.and (i32.ne (local.get $n) (i32.const 0)) (i32.ge_u (global.get $signature-count) (i32.const M4_NAME_INDEX_MIN)))
			(then
				;; Anonymous signatures are skipped, and old source pointers are cleared on first use.
				(if (i32.eqz (global.get $types-indexed))
					(then (call $zero-bytes (global.get $type-name-index) (i32.const M4_TYPE_NAME_INDEX_BYTES)))
				)
				(local.set $i (call $indexed-name (global.get $signature-base) (i32.const 544)
					(global.get $signature-count) (global.get $types-indexed)
					(global.get $type-name-index) (i32.const M4_TYPE_NAME_INDEX_MASK)
					(i32.const 1) (local.get $p) (local.get $n)))
				(global.set $types-indexed (global.get $signature-count))
				(return (local.get $i))
			)
		)

		;; Finish after all explicit declarations, returning -1 for a missing name.
		(block $done
			;; Compare source-backed identifier bytes without interning them.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (global.get $signature-count)))
				(local.set $s (call $signature (local.get $i)))
				;; Only an exact name span identifies a declaration.
				(if
					;; Compare bytes only after the complete span/prefix guard succeeds.
					(if (result i32)
						(i32.eq (local.get $n) (i32.load offset=4 (local.get $s)))
						(then
							(call $equal (local.get $p) (i32.load (local.get $s)) (local.get $n))
						)
						;; An incompatible span cannot match this name or prefix.
						(else (i32.const 0))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
		(i32.const -1)
	)

	;; Resolve an explicit type name/index after all declarations exist, reporting a reference error at its use.
	(func $type-target
		(param $value i32)
		(param $length i32)
		(param $offset i32)
		(result i32)

		;; Named references use the type namespace rather than the function namespace.
		(if (local.get $length)
			(then
				(local.set $value (call $find-type (local.get $value) (local.get $length)))
			)
		)
		;; Every explicit type index must lie within the declared prefix of the signature arena.
		(if (i32.ge_u (local.get $value) (global.get $signature-count))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
			)
		)
		(local.get $value)
	)

	;; Consume a type-use reference into value/length/offset fields at 0/4/8, with presence flag at 12.
	(func $read-type-use
		(param $record i32)

		;; A type-use is unique within a function or indirect call signature.
		(if (i32.load offset=12 (local.get $record))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		(i32.store offset=8 (local.get $record) (global.get $tok))
		(call $next)
		(i32.store offset=12 (local.get $record) (i32.const 1))
		;; Named references remain source-backed until module-wide resolution.
		(if (call $named)
			(then
				(i32.store (local.get $record) (global.get $tok))
				(i32.store offset=4 (local.get $record) (global.get $len))
				(call $next)
			)
			;; Numeric references also allow forward declarations, so bounds are checked later.
			(else
				(i32.store (local.get $record) (call $index))
			)
		)
		(call $expect (i32.const 2))
	)

	;; Parse inline parameter/result groups into a signature, replaying an opening that belongs to the body.
	(func $signature-groups
		(param $s i32)
		(local $open i32)
		(local $result i32)
		(local $count i32)
		(local $type i32)

		;; Stop at the first non-signature token or any earlier syntax failure.
		(block $done
			;; Parameter groups precede result groups and consume all their scalar type atoms.
			(loop $groups
				(br_if $done (global.get $error))
				(br_if $done (i32.ne (global.get $kind) (i32.const 1)))
				(local.set $open (global.get $tok))
				(call $next)
				;; Unrecognized headers are instructions, not implicitly ignored signature annotations.
				(if
					(i32.eqz
						(i32.or
							(call $is-word (i32.const 64) (i32.const 5))
							(call $is-word (i32.const 17) (i32.const 6))
						)
					)
					(then
						(global.set $pos (local.get $open))
						(call $next)
						(br $done)
					)
				)
				(i32.store offset=28
					(local.get $s)
					(i32.or (i32.load offset=28 (local.get $s)) (i32.const 2))
				)
				;; Parameter declarations cannot follow a result declaration.
				(if (call $is-word (i32.const 64) (i32.const 5))
					(then
						;; The signature phase is independent of whether the result group is empty.
						(if (local.get $result)
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
								(return)
							)
						)
						(call $next)
						;; A type declaration may annotate one parameter name; names do not affect structural equality.
						(if (call $named)
							(then
								;; Indirect call annotations cannot bind parameter names.
								(if (i32.ge_u (local.get $s) (call $signature (i32.const M4_CAP_TYPES)))
									(then
										(call $fail (i32.const M4_ERR_SYNTAX))
										(return)
									)
								)
								(call $next)
								(local.set $type (call $value-type))
								(local.set $count (i32.load offset=8 (local.get $s)))
								;; Enforce the parameter capacity before storing its type slot.
								(if (i32.ge_u (local.get $count) (i32.const 128))
									(then
										(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
										(return)
									)
								)
								(i32.store offset=32
									(i32.add (local.get $s) (i32.mul (local.get $count) (i32.const 4)))
									(local.get $type)
								)
								(i32.store offset=8 (local.get $s) (i32.add (local.get $count) (i32.const 1)))
								(call $expect (i32.const 2))
								(br $groups)
							)
						)
						;; Finish a parameter group after its closing parenthesis.
						(block $params-done
							;; Append each unnamed parameter in source order, bounded by 64 slots.
							(loop $params
								(br_if $params-done (global.get $error))
								(br_if $params-done (i32.eq (global.get $kind) (i32.const 2)))
								(local.set $count (i32.load offset=8 (local.get $s)))
								;; Avoid crossing the signature record boundary.
								(if (i32.ge_u (local.get $count) (i32.const 128))
									(then
										(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
										(return)
									)
								)
								(local.set $type (call $value-type))
								(i32.store offset=32
									(i32.add (local.get $s) (i32.mul (local.get $count) (i32.const 4)))
									(local.get $type)
								)
								(i32.store offset=8 (local.get $s) (i32.add (local.get $count) (i32.const 1)))
								(br $params)
							)
						)
					)
					;; Result groups append their types in source order.
					(else
						(local.set $result (i32.const 1))
						(call $next)
						;; Stop after consuming the current group or encountering an error.
						(block $results-done
							;; Empty groups add no type; multiple groups extend the same vector.
							(loop $results
								(br_if $results-done (global.get $error))
								(br_if $results-done (i32.eq (global.get $kind) (i32.const 2)))
								(i32.store offset=12
									(local.get $s)
									(call $shape-append (i32.load offset=12 (local.get $s)) (call $value-type))
								)
								(br $results)
							)
						)
					)
				)
				(call $expect (i32.const 2))
				(br $groups)
			)
		)
	)

	;; Parse one explicit function type and reject duplicate identifiers or capacity exhaustion.
	(func $parse-type
		(local $s i32)
		(local $p i32)
		(local $n i32)
		(local $index i32)
		(local $sub i32)

		;; Explicit types reserve the first 256 records; indirect signatures occupy the second prefix.
		(if (i32.ge_u (global.get $signature-count) (i32.const M4_CAP_TYPES))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(local.set $s (call $signature (global.get $signature-count)))
		(call $zero-bytes (local.get $s) (i32.const 544))
		(i32.store offset=16 (local.get $s) (global.get $tok))
		(call $next)
		;; An optional identifier participates only in the explicit type namespace.
		(if (call $named)
			(then
				(local.set $p (global.get $tok))
				(local.set $n (global.get $len))
				;; Duplicate names are invalid even when their structural signatures agree.
				(if (i32.ne (call $find-type (local.get $p) (local.get $n)) (i32.const -1))
					(then
						(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
						(return)
					)
				)
				(i32.store (local.get $s) (local.get $p))
				(i32.store offset=4 (local.get $s) (local.get $n))
				(call $next)
			)
		)
		(local.set $index (global.get $signature-count))
		(global.set $signature-count (i32.add (local.get $index) (i32.const 1)))
		(call $initialize-heap-type (local.get $index))
		(call $expect (i32.const 1))
		;; A subtype wrapper precedes the composite function, struct or array declaration.
		(if (call $is-ref-word (i32.const 23))
			(then
				(call $next)
				(local.set $sub (i32.const 1))
				(i32.store offset=12 (call $heap-record (local.get $index)) (i32.const 0))
				;; The optional final keyword prevents further declared subtyping.
				(if (call $is-ref-word (i32.const 24))
					(then
						(call $next)
						(i32.store offset=12 (call $heap-record (local.get $index)) (i32.const 1))
					)
				)
				;; A subtype has at most one declared supertype.
				(if (i32.or (call $named) (call $index-token))
					(then
						(i32.store offset=16 (call $heap-record (local.get $index)) (call $reference-type))
					)
				)
				(call $expect (i32.const 1))
			)
		)
		(call $parse-composite-type (local.get $index))
		(call $expect (i32.const 2))
		;; Wrapped subtypes have an additional close before the type declaration ends.
		(if (local.get $sub)
			(then
				(call $expect (i32.const 2))
			)
		)
		(call $expect (i32.const 2))
	)

	;; Allocate a deferred indirect-call signature; explicit references and inline types are resolved together later.
	(func $indirect-signature
		(result i32)
		(local $index i32)
		(local $s i32)
		(local $open i32)

		;; Bound anonymous signatures independently from explicit type declarations.
		(if (i32.ge_u (global.get $indirect-type-count) (i32.const 1024))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i32.const 0))
			)
		)
		(local.set $index (i32.add (i32.const M4_CAP_TYPES) (global.get $indirect-type-count)))
		(global.set $indirect-type-count
			(i32.add (global.get $indirect-type-count) (i32.const 1))
		)
		(local.set $s (call $signature (local.get $index)))
		(call $zero-bytes (local.get $s) (i32.const 544))
		;; Indirect signatures have no type name, so their first pair retains the optional table target.
		(drop (call $table-reference (local.get $s)))
		(i32.store offset=16 (local.get $s) (global.get $tok))
		;; A leading type-use can be followed by an explicit matching inline signature.
		(if (i32.eq (global.get $kind) (i32.const 1))
			(then
				(local.set $open (global.get $tok))
				(call $next)
				;; Type uses retain their source span without changing explicit type indices.
				(if (call $is-word (i32.const 3856) (i32.const 4))
					(then
						(call $read-type-use (i32.add (local.get $s) (i32.const 16)))
						(i32.store offset=28 (local.get $s) (i32.const 1))
					)
					;; Other openings belong to inline declarations or folded call arguments.
					(else
						(global.set $pos (local.get $open))
						(call $next)
					)
				)
			)
		)
		(call $signature-groups (local.get $s))
		(local.get $index)
	)

	;; Compare one function against a structural signature rather than requiring matching nominal type indices.
	(func $function-matches
		(param $index i32)
		(param $s i32)
		(result i32)
		(local $f i32)
		(local $j i32)

		(local.set $f (call $function (local.get $index)))
		;; Counts and the optional result must agree before reading parameter type slots.
		(if
			(i32.or
				(i32.ne (i32.load offset=16 (local.get $f)) (i32.load offset=8 (local.get $s)))
				(i32.eqz
					(call $shape-equal
						(i32.load offset=24 (local.get $f))
						(i32.load offset=12 (local.get $s))
					)
				)
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Complete after all parameters match by scalar width.
		(block $done
			;; Compare the ordered vectors, including mixed-width signatures.
			(loop $params
				(br_if $done (i32.eq (local.get $j) (i32.load offset=8 (local.get $s))))
				;; A single width mismatch invalidates the call signature.
				(if
					(i32.eqz
						(call $type-equal
							(i32.load (call $local-type (local.get $index) (local.get $j)))
							(i32.load offset=32 (i32.add (local.get $s) (i32.mul (local.get $j) (i32.const 4))))
						)
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $j (i32.add (local.get $j) (i32.const 1)))
				(br $params)
			)
		)
		(i32.const 1)
	)

	;; Check an indirect call against the selected function's complete declared recursive type.
	(func $indirect-function-matches
		(param $function i32)
		(param $signature i32)
		(result i32)

		;; Explicit type uses preserve recursive-group identity and declared subtyping.
		(if (i32.and (i32.load offset=28 (local.get $signature)) (i32.const 1))
			(then
				(return
					(call $heap-type-subtype
						(call $reference-heap (call $function-reference-type (local.get $function)))
						(i32.load offset=16 (local.get $signature))
					)
				)
			)
		)
		(i32.and
			(call $implicit-heap-type
				(call $reference-heap (call $function-reference-type (local.get $function)))
			)
			(call $function-matches (local.get $function) (local.get $signature))
		)
	)

	;; Expand inline function types after the explicit declarations, reusing equal ordered signatures.
	(func $intern-function-types
		(local $i i32)
		(local $j i32)
		(local $k i32)
		(local $f i32)
		(local $s i32)
		(local $use-index i32)
		(local $ready i32)
		(local $hash i32)
		(local $link i32)

		(local.set $use-index
			(i32.or (i32.ge_u (global.get $signature-count) (i32.const M4_SIGNATURE_MIN_TYPES))
				(i32.ge_u (global.get $function-count) (i32.const M4_SIGNATURE_MIN_FUNCTIONS))))

		;; Visit functions in source order so numeric references see the prescribed implicit type indices.
		(block $done
			;; Functions with explicit type uses acquire their signatures during subsequent resolution.
			(loop $functions
				(br_if $done (i32.eq (local.get $i) (global.get $function-count)))
				;; Only an absent type use adds an implicit declaration.
				(if (i32.eqz (i32.load offset=12 (call $function-type (local.get $i))))
					(then
						;; Larger namespaces filter structural comparisons through temporary hash buckets.
						(if (local.get $use-index)
							(then
								;; Literal scratch becomes available only after parsing has completed.
								(if (i32.eqz (local.get $ready))
									(then (call $index-declared-signatures) (local.set $ready (i32.const 1)))
								)
								(local.set $f (call $function (local.get $i)))
								(local.set $hash (call $signature-hash (call $local-type (local.get $i) (i32.const 0))
									(i32.load offset=16 (local.get $f)) (i32.load offset=24 (local.get $f))))
								(local.set $link (i32.load (i32.add (global.get $fp-t-base)
									(i32.mul (i32.and (local.get $hash) (i32.const M4_SIGNATURE_BUCKET_MASK)) (i32.const M4_U32_BYTES)))))
								(local.set $j (global.get $signature-count))
								;; A bucket miss retains the original append-at-end behavior.
								(block $found
									;; Hash equality is only a filter; collisions still require complete structural equality.
									(loop $candidates
										(br_if $found (i32.eqz (local.get $link)))
										(local.set $s (call $heap-record (i32.sub (local.get $link) (i32.const 1))))
										;; Differing hashes cannot represent equal ordered signatures.
										(if (i32.eq (i32.load offset=M4_SIGNATURE_HASH_OFFSET (local.get $s)) (local.get $hash))
											(then
												;; References retain the existing recursive-aware equality checks.
												(if (call $function-matches (local.get $i) (call $signature (i32.sub (local.get $link) (i32.const 1))))
													(then (local.set $j (i32.sub (local.get $link) (i32.const 1))) (br $found))
												)
											)
										)
										(local.set $link (i32.load offset=M4_SIGNATURE_LINK_OFFSET (local.get $s)))
										(br $candidates)
									)
								)
							)
							;; Tiny modules retain the original scan without hashing or bucket setup.
							(else
								(local.set $j (i32.const 0))
								;; Stop at an existing structural match or the end of the current type namespace.
								(block $found
									;; Include previously expanded types when deduplicating later functions.
									(loop $types
										(br_if $found (i32.eq (local.get $j) (global.get $signature-count)))
										(br_if $found
											(i32.and
												(call $implicit-heap-type (local.get $j))
												(call $function-matches (local.get $i) (call $signature (local.get $j)))
											)
										)
										(local.set $j (i32.add (local.get $j) (i32.const 1)))
										(br $types)
									)
								)
							)
						)
						;; A new signature has anonymous identity and copies the function's scalar vector.
						(if (i32.eq (local.get $j) (global.get $signature-count))
							(then
								;; Keep implicit types separate from the indirect-call signature arena.
								(if (i32.ge_u (local.get $j) (i32.const M4_CAP_TYPES))
									(then
										(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
										(return)
									)
								)
								(local.set $f (call $function (local.get $i)))
								(local.set $s (call $signature (local.get $j)))
								(call $initialize-heap-type (local.get $j))
								(i32.store offset=8 (local.get $s) (i32.load offset=16 (local.get $f)))
								(i32.store offset=12 (local.get $s) (i32.load offset=24 (local.get $f)))
								(local.set $k (i32.const 0))
								;; Copy only parameters; locals do not belong to function types.
								(block $copied
									;; Preserve mixed scalar widths and their declaration order.
									(loop $params
										(br_if $copied (i32.eq (local.get $k) (i32.load offset=16 (local.get $f))))
										(i32.store offset=32
											(i32.add (local.get $s) (i32.mul (local.get $k) (i32.const 4)))
											(i32.load (call $local-type (local.get $i) (local.get $k)))
										)
										(local.set $k (i32.add (local.get $k) (i32.const 1)))
										(br $params)
									)
								)
								;; A newly appended type could not equal an earlier candidate; add it for subsequent functions.
								(if (local.get $use-index)
									(then (call $index-signature (local.get $j) (local.get $hash)))
								)

								(global.set $signature-count (i32.add (global.get $signature-count) (i32.const 1)))
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $functions)
			)
		)
	)

	;; Resolve explicit type uses, inserting inherited parameters ahead of locals while preserving names and indices.
	(func $resolve-signatures
		(local $i i32)
		(local $j i32)
		(local $m i32)
		(local $s i32)
		(local $t i32)
		(local $f i32)
		(local $count i32)
		(local $old i32)
		(local $to i32)
		(local $resolved i32)

		;; Finish once all deferred function type uses have been applied.
		(block $functions-done
			;; Types may be declared after their function uses, so resolution happens after module parsing.
			(loop $functions
				(br_if $functions-done (global.get $error))
				(br_if $functions-done (i32.eq (local.get $i) (global.get $function-count)))
				(global.set $current-function (local.get $i))
				(local.set $f (call $function (local.get $i)))
				(local.set $m (call $function-type (local.get $i)))
				;; Functions without explicit type uses already have complete inline signatures.
				(if (i32.load offset=12 (local.get $m))
					(then
						(local.set $s
							(call $signature
								(call $type-target
									(i32.load (local.get $m))
									(i32.load offset=4 (local.get $m))
									(i32.load offset=8 (local.get $m))
								)
							)
						)
						(br_if $functions-done (global.get $error))
						;; Nonempty inline parameter/result vectors require complete structural agreement.
						(if (i32.or (i32.load offset=16 (local.get $f)) (i32.load offset=24 (local.get $f)))
							(then
								;; Contradictory type uses fail validation before any function can execute.
								(if (i32.eqz (call $function-matches (local.get $i) (local.get $s)))
									(then
										(global.set $tok (i32.load offset=8 (local.get $m)))
										(call $fail (i32.const M4_ERR_SYNTAX))
									)
								)
							)
							;; Absent or empty inline signatures inherit both ordered parameters and the result.
							(else
								(local.set $count (i32.load offset=8 (local.get $s)))
								(local.set $old (i32.load offset=20 (local.get $f)))
								;; Parameters and declared locals share the same bounded frame.
								(if (i32.gt_u (i32.add (local.get $old) (local.get $count)) (i32.const M4_CAP_LOCALS))
									(then
										(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
										(return)
									)
								)
								(local.set $j (local.get $old))
								;; End after shifting all old locals upward from the end to prevent overlap.
								(block $shift-done
									;; Copy names and type slots together so named local references resolve at their final slots.
									(loop $shift
										(br_if $shift-done (i32.eqz (local.get $j)))
										(local.set $j (i32.sub (local.get $j) (i32.const 1)))
										(local.set $to (i32.add (local.get $j) (local.get $count)))
										(i64.store
											(call $local-name (local.get $to))
											(i64.load (call $local-name (local.get $j)))
										)
										(i32.store
											(call $local-type (local.get $i) (local.get $to))
											(i32.load (call $local-type (local.get $i) (local.get $j)))
										)
										(br $shift)
									)
								)
								(local.set $j (i32.const 0))
								;; Finish after installing every inherited parameter with an anonymous local-name slot.
								(block $copy-done
									;; Type-declaration parameter names are annotations, not function local bindings.
									(loop $copy
										(br_if $copy-done (i32.eq (local.get $j) (local.get $count)))
										(i64.store (call $local-name (local.get $j)) (i64.const 0))
										(i32.store
											(call $local-type (local.get $i) (local.get $j))
											(i32.load offset=32 (i32.add (local.get $s) (i32.mul (local.get $j) (i32.const 4))))
										)
										(local.set $j (i32.add (local.get $j) (i32.const 1)))
										(br $copy)
									)
								)
								(i32.store offset=16 (local.get $f) (local.get $count))
								(i32.store offset=20 (local.get $f) (i32.add (local.get $old) (local.get $count)))
								(i32.store offset=24 (local.get $f) (i32.load offset=12 (local.get $s)))
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $functions)
			)
		)
		(local.set $i (i32.const 0))
		;; Finish once every indirect signature has resolved its optional explicit reference.
		(block $calls-done
			;; Anonymous signatures occupy a disjoint prefix, preserving explicit source-order type indices.
			(loop $calls
				(br_if $calls-done (global.get $error))
				(br_if $calls-done (i32.eq (local.get $i) (global.get $indirect-type-count)))
				(local.set $s (call $signature (i32.add (i32.const M4_CAP_TYPES) (local.get $i))))
				;; An indirect call with no explicit type use already contains its inline signature.
				(if (i32.and (i32.load offset=28 (local.get $s)) (i32.const 1))
					(then
						(global.set $tok (i32.load offset=24 (local.get $s)))
						(local.set $resolved
							(call $type-target
								(i32.load offset=16 (local.get $s))
								(i32.load offset=20 (local.get $s))
								(i32.load offset=24 (local.get $s))
							)
						)
						(local.set $t (call $signature (local.get $resolved)))
						(br_if $calls-done (global.get $error))
						;; Nonempty inline vectors must describe the entire referenced signature.
						(if (i32.or (i32.load offset=8 (local.get $s)) (i32.load offset=12 (local.get $s)))
							(then
								;; Parameter count and result type must agree before vector comparison.
								(if
									(i32.or
										(i32.ne (i32.load offset=8 (local.get $s)) (i32.load offset=8 (local.get $t)))
										(i32.eqz
											(call $shape-equal
												(i32.load offset=12 (local.get $s))
												(i32.load offset=12 (local.get $t))
											)
										)
									)
									(then
										(call $fail (i32.const M4_ERR_SYNTAX))
										(return)
									)
								)
								(local.set $j (i32.const 0))
								;; Finish after matching every inline parameter width.
								(block $match-done
									;; Compare structural types rather than declaration identities.
									(loop $match
										(br_if $match-done (i32.eq (local.get $j) (i32.load offset=8 (local.get $s))))
										;; A known width mismatch is invalid even in unreachable code.
										(if
											(i32.ne
												(i32.load offset=32 (i32.add (local.get $s) (i32.mul (local.get $j) (i32.const 4))))
												(i32.load offset=32 (i32.add (local.get $t) (i32.mul (local.get $j) (i32.const 4))))
											)
											(then
												(call $fail (i32.const M4_ERR_SYNTAX))
												(return)
											)
										)
										(local.set $j (i32.add (local.get $j) (i32.const 1)))
										(br $match)
									)
								)
							)
							;; Absent or empty inline groups inherit the referenced scalar vector.
							(else
								(i32.store offset=8 (local.get $s) (i32.load offset=8 (local.get $t)))
								(i32.store offset=12 (local.get $s) (i32.load offset=12 (local.get $t)))
								(local.set $j (i32.const 0))
								;; Finish after copying the referenced parameter vector.
								(block $inherit-done
									;; Only declared parameter bytes are copied; names remain local to explicit declarations.
									(loop $inherit
										(br_if $inherit-done (i32.eq (local.get $j) (i32.load offset=8 (local.get $t))))
										(i32.store offset=32
											(i32.add (local.get $s) (i32.mul (local.get $j) (i32.const 4)))
											(i32.load offset=32 (i32.add (local.get $t) (i32.mul (local.get $j) (i32.const 4))))
										)
										(local.set $j (i32.add (local.get $j) (i32.const 1)))
										(br $inherit)
									)
								)
							)
						)
						;; Retain the resolved expected heap index and its original diagnostic offset.
						(i32.store offset=16 (local.get $s) (local.get $resolved))
						(i32.store offset=20 (local.get $s) (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $calls)
			)
		)
	)
