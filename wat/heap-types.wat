	;; Locate one composite type descriptor in the source-order type namespace.
	(func $heap-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $heap-type-base) (i32.mul (local.get $index) (i32.const 64)))
	)

	;; Locate one aggregate field descriptor: storage type, mutability and optional source-backed name.
	(func $field-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $field-type-base) (i32.mul (local.get $index) (i32.const 16)))
	)

	;; Initialize the metadata for a singleton or member of a recursive composite type group.
	(func $initialize-heap-type
		(param $index i32)
		(local $record i32)

		(local.set $record (call $heap-record (local.get $index)))
		(call $zero-bytes (local.get $record) (i32.const 64))
		(i32.store offset=4
			(local.get $record)
			(select (global.get $rec-start) (local.get $index) (global.get $rec-active))
		)
		(i32.store offset=8 (local.get $record) (i32.const 1))
		(i32.store offset=12 (local.get $record) (i32.const 1))
		(i32.store offset=16 (local.get $record) (i32.const -1))
		(i32.store offset=20 (local.get $record) (global.get $field-type-count))
		(i32.store offset=32 (local.get $record) (global.get $tok))
	)

	;; Classify a declared composite heap as function, struct or array for reference subtyping.
	(func $heap-category
		(param $index i32)
		(result i32)

		;; Failed heap resolution cannot address the descriptor arena.
		(if (i32.ge_u (local.get $index) (global.get $signature-count))
			(then
				(return (i32.const 0))
			)
		)
		(select
			(i32.const 5)
			(select
				(i32.const 22)
				(i32.const 24)
				(i32.eq (i32.load (call $heap-record (local.get $index))) (i32.const 1))
			)
			(i32.eqz (i32.load (call $heap-record (local.get $index))))
		)
	)

	;; Determine whether an explicit type is a canonical candidate for an implicit function type.
	(func $implicit-heap-type
		(param $index i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $heap-record (local.get $index)))
		(i32.and
			(i32.eqz (i32.load (local.get $record)))
			(i32.and
				(i32.eq (i32.load offset=8 (local.get $record)) (i32.const 1))
				(i32.and
					(i32.load offset=12 (local.get $record))
					(i32.eq (i32.load offset=16 (local.get $record)) (i32.const -1))
				)
			)
		)
	)

	;; Parse a field storage type, preserving packed i8 and i16 types separately from operand i32 values.
	(func $storage-type
		(result i32)

		;; Packed bytes use a storage-only code and unpack to ordinary i32 operands.
		(if (call $is-ref-word (i32.const 26))
			(then
				(call $next)
				(return (i32.const 12))
			)
		)
		;; Packed halfwords retain their different truncation width.
		(if (call $is-ref-word (i32.const 27))
			(then
				(call $next)
				(return (i32.const 13))
			)
		)
		(call $value-type)
	)

	;; Parse and append one aggregate field, checking per-type field name uniqueness.
	(func $append-field
		(param $heap i32)
		(param $name i32)
		(param $length i32)
		(local $type i32)
		(local $mutable i32)
		(local $record i32)
		(local $i i32)
		(local $open i32)

		;; Only a mut wrapper changes field mutability; parenthesized ref types belong to value-type.
		(if
			(i32.and (i32.eq (global.get $kind) (i32.const 1)) (i32.eqz (call $reference-type-token)))
			(then
				(local.set $open (i32.const 1))
				(call $next)
				(call $word (i32.const 96) (i32.const 3))
				(local.set $mutable (i32.const 1))
			)
		)
		(local.set $type (call $storage-type))
		;; Mut wrappers close after exactly one storage type.
		(if (local.get $open)
			(then
				(call $expect (i32.const 2))
			)
		)
		;; Bound the shared field arena before creating a descriptor.
		(if (i32.ge_u (global.get $field-type-count) (i32.const 32768))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $i (i32.load offset=20 (local.get $heap)))
		;; Compare any new field name with the preceding fields of this composite type.
		(block $checked
			;; Anonymous fields cannot introduce duplicate names.
			(loop $names
				(br_if $checked (i32.eqz (local.get $length)))
				(br_if $checked (i32.eq (local.get $i) (global.get $field-type-count)))
				(local.set $record (call $field-record (local.get $i)))
				;; Field names match only when their full source-backed byte strings agree.
				(if
					(i32.and
						(i32.eq (local.get $length) (i32.load offset=12 (local.get $record)))
						(call $equal
							(local.get $name)
							(i32.load offset=8 (local.get $record))
							(local.get $length)
						)
					)
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(local.set $record (call $field-record (global.get $field-type-count)))
		(i32.store (local.get $record) (local.get $type))
		(i32.store offset=4 (local.get $record) (local.get $mutable))
		(i32.store offset=8 (local.get $record) (local.get $name))
		(i32.store offset=12 (local.get $record) (local.get $length))
		(global.set $field-type-count (i32.add (global.get $field-type-count) (i32.const 1)))
		(i32.store offset=24
			(local.get $heap)
			(i32.add (i32.load offset=24 (local.get $heap)) (i32.const 1))
		)
	)

	;; Parse the body of a function, struct or array composite type after its opening parenthesis.
	(func $parse-composite-type
		(param $index i32)
		(local $heap i32)
		(local $name i32)
		(local $length i32)

		(local.set $heap (call $heap-record (local.get $index)))
		;; Function composites retain the ordinary ordered parameter and result signature.
		(if (call $is-word (i32.const 6) (i32.const 4))
			(then
				(call $next)
				(call $signature-groups (call $signature (local.get $index)))
				(return)
			)
		)
		;; Array composites contain exactly one field storage type.
		(if (call $is-ref-word (i32.const 6))
			(then
				(call $next)
				(i32.store (local.get $heap) (i32.const 2))
				(call $append-field (local.get $heap) (i32.const 0) (i32.const 0))
				(return)
			)
		)
		;; Struct composites contain a sequence of named or anonymous field groups.
		(if (i32.eqz (call $is-ref-word (i32.const 5)))
			(then
				(call $fail (i32.const 1))
				(return)
			)
		)
		(i32.store (local.get $heap) (i32.const 1))
		(call $next)
		;; Finish at the struct composite's closing parenthesis.
		(block $done
			;; Each field group can abbreviate several anonymous fields.
			(loop $fields
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $kind) (i32.const 2)))
				(call $expect (i32.const 1))
				;; Struct contents must consist of field declarations.
				(if (i32.eqz (call $is-ref-word (i32.const 25)))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $next)
				(local.set $name (i32.const 0))
				(local.set $length (i32.const 0))
				;; A field name annotates exactly one following storage type.
				(if (call $named)
					(then
						(local.set $name (global.get $tok))
						(local.set $length (global.get $len))
						(call $next)
					)
				)
				;; Complete the current field group's ordered storage list.
				(block $group-done
					;; Empty anonymous groups are harmless; named groups need exactly one field.
					(loop $types
						(br_if $group-done (global.get $error))
						(br_if $group-done (i32.eq (global.get $kind) (i32.const 2)))
						(call $append-field (local.get $heap) (local.get $name) (local.get $length))
						;; Named groups cannot abbreviate more than one field.
						(if (local.get $length)
							(then
								(br $group-done)
							)
						)
						(br $types)
					)
				)
				(call $expect (i32.const 2))
				(br $fields)
			)
		)
	)

	;; Parse a recursive group and publish its complete size on every member descriptor.
	(func $parse-rec-group
		(local $start i32)
		(local $i i32)
		(local $size i32)

		(local.set $start (global.get $signature-count))
		(global.set $rec-start (local.get $start))
		(global.set $rec-active (i32.const 1))
		(call $next)
		;; Finish after the last type declaration in this recursive group.
		(block $done
			;; The group binds a single shared heap namespace before any type validation.
			(loop $types
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $kind) (i32.const 2)))
				(call $expect (i32.const 1))
				;; Recursive groups contain type declarations rather than executable module fields.
				(if (i32.eqz (call $is-word (i32.const 3856) (i32.const 4)))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $parse-type)
				(br $types)
			)
		)
		(global.set $rec-active (i32.const 0))
		(call $expect (i32.const 2))
		(local.set $size (i32.sub (global.get $signature-count) (local.get $start)))
		(local.set $i (local.get $start))
		;; Publish the size even on an unused group so canonicalization preserves group identity.
		(block $published
			;; Member order is significant when matching isomorphic recursive groups.
			(loop $members
				(br_if $published (i32.eq (local.get $i) (global.get $signature-count)))
				(i32.store offset=8 (call $heap-record (local.get $i)) (local.get $size))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $members)
			)
		)
	)

	;; Check a heap type occurrence against its declaration's recursive group scope.
	(func $check-scoped-type
		(param $type i32)
		(param $bound i32)

		;; Abstract reference and numeric types have no scoped declaration index.
		(if (i32.ge_u (local.get $type) (i32.const 64))
			(then
				;; A type can refer to its group members and earlier groups, but never later groups.
				(if (i32.ge_u (call $reference-heap (local.get $type)) (local.get $bound))
					(then
						(call $fail (i32.const 10))
					)
				)
			)
		)
	)

	;; Match a declared heap subtype by walking its validated chain of explicit supertypes.
	(func $heap-type-subtype
		(param $actual i32)
		(param $expected i32)
		(result i32)
		(local $super i32)

		;; Stop at a canonical match or a heap declaration without a supertype.
		(block $done
			;; Declared supertype chains point backward and therefore terminate.
			(loop $parents
				;; Canonical equality satisfies a declared subtype relation immediately.
				(if (call $heap-type-equal (local.get $actual) (local.get $expected))
					(then
						(return (i32.const 1))
					)
				)
				(br_if $done (global.get $error))
				(local.set $super (i32.load offset=16 (call $heap-record (local.get $actual))))
				(br_if $done (i32.eq (local.get $super) (i32.const -1)))
				(local.set $actual (call $reference-heap (local.get $super)))
				(br $parents)
			)
		)
		(i32.const 0)
	)

	;; Verify a declared structural extension of its direct supertype.
	(func $heap-extends
		(param $child i32)
		(param $parent i32)
		(result i32)
		(local $c i32)
		(local $p i32)
		(local $i i32)
		(local $cf i32)
		(local $pf i32)

		(local.set $c (call $heap-record (local.get $child)))
		(local.set $p (call $heap-record (local.get $parent)))
		;; Composite kinds and finality constrain all explicit subtypes.
		(if
			(i32.or
				(i32.ne (i32.load (local.get $c)) (i32.load (local.get $p)))
				(i32.load offset=12 (local.get $p))
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Function subtypes are contravariant in parameters and covariant in results.
		(if (i32.eqz (i32.load (local.get $c)))
			(then
				(local.set $c (call $signature (local.get $child)))
				(local.set $p (call $signature (local.get $parent)))
				;; Function parameter arities must agree.
				(if (i32.ne (i32.load offset=8 (local.get $c)) (i32.load offset=8 (local.get $p)))
					(then
						(return (i32.const 0))
					)
				)
				;; Finish after checking every contravariant parameter.
				(block $done
					;; A parent parameter must be accepted by the child implementation.
					(loop $params
						(br_if $done (i32.eq (local.get $i) (i32.load offset=8 (local.get $p))))
						;; Function parameters must satisfy contravariance against the declared supertype.
						(if
							(i32.eqz
								(call $type-compatible
									(i32.load offset=32 (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 4))))
									(i32.load offset=32 (i32.add (local.get $c) (i32.mul (local.get $i) (i32.const 4))))
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
				(return
					(call $shape-compatible
						(i32.load offset=12 (local.get $c))
						(i32.load offset=12 (local.get $p))
					)
				)
			)
		)
		;; Structs may append fields; arrays retain their singleton field.
		(if
			(i32.lt_u (i32.load offset=24 (local.get $c)) (i32.load offset=24 (local.get $p)))
			(then
				(return (i32.const 0))
			)
		)
		;; Complete after every inherited field has matched its storage and mutability requirements.
		(block $done
			;; Immutable fields are covariant; mutable fields are invariant.
			(loop $fields
				(br_if $done (i32.eq (local.get $i) (i32.load offset=24 (local.get $p))))
				(local.set $cf
					(call $field-record (i32.add (i32.load offset=20 (local.get $c)) (local.get $i)))
				)
				(local.set $pf
					(call $field-record (i32.add (i32.load offset=20 (local.get $p)) (local.get $i)))
				)
				;; Mutability cannot change in a structural subtype.
				(if (i32.ne (i32.load offset=4 (local.get $cf)) (i32.load offset=4 (local.get $pf)))
					(then
						(return (i32.const 0))
					)
				)
				;; Packed storage types require exact width, while value fields use ordinary subtyping.
				(if
					(i32.eqz (call $type-compatible (i32.load (local.get $cf)) (i32.load (local.get $pf))))
					(then
						(return (i32.const 0))
					)
				)
				;; A mutable inherited field must also accept writes of its parent's storage type.
				(if
					(i32.and
						(i32.load offset=4 (local.get $cf))
						(i32.eqz (call $type-compatible (i32.load (local.get $pf)) (i32.load (local.get $cf))))
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $fields)
			)
		)
		(i32.const 1)
	)

	;; Validate recursive group scope, declared finality and structural subtype constraints.
	(func $validate-heap-types
		(local $i i32)
		(local $j i32)
		(local $heap i32)
		(local $signature i32)
		(local $bound i32)
		(local $super i32)

		;; Complete after all explicit composite types have been validated.
		(block $done
			;; Implicit function signatures are added only after this declaration validation pass.
			(loop $types
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $signature-count)))
				(local.set $heap (call $heap-record (local.get $i)))
				(local.set $bound
					(i32.add (i32.load offset=4 (local.get $heap)) (i32.load offset=8 (local.get $heap)))
				)
				(global.set $tok (i32.load offset=32 (local.get $heap)))
				(local.set $j (i32.const 0))
				;; Function composites scope-check their complete parameter and result vectors.
				(if (i32.eqz (i32.load (local.get $heap)))
					(then
						(local.set $signature (call $signature (local.get $i)))
						;; Finish after every function parameter type has been scope-checked.
						(block $params-done
							;; Forward references are limited to the current recursive group.
							(loop $params
								(br_if $params-done (i32.eq (local.get $j) (i32.load offset=8 (local.get $signature))))
								(call $check-scoped-type
									(i32.load offset=32
										(i32.add (local.get $signature) (i32.mul (local.get $j) (i32.const 4)))
									)
									(local.get $bound)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $params)
							)
						)
						(local.set $j (i32.const 0))
						;; Finish after every function result type has been scope-checked.
						(block $results-done
							;; Result references obey the same declaration scope as parameters.
							(loop $results
								(br_if $results-done
									(i32.eq (local.get $j) (call $shape-count (i32.load offset=12 (local.get $signature))))
								)
								(call $check-scoped-type
									(call $shape-type (i32.load offset=12 (local.get $signature)) (local.get $j))
									(local.get $bound)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $results)
							)
						)
					)
					;; Aggregate fields may refer to their current recursive group and preceding groups.
					(else
						;; Complete after all aggregate field types have been checked.
						(block $fields-done
							;; Packed fields have no heap namespace use.
							(loop $fields
								(br_if $fields-done (i32.eq (local.get $j) (i32.load offset=24 (local.get $heap))))
								(call $check-scoped-type
									(i32.load
										(call $field-record (i32.add (i32.load offset=20 (local.get $heap)) (local.get $j)))
									)
									(local.get $bound)
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $fields)
							)
						)
					)
				)
				(local.set $super (i32.load offset=16 (local.get $heap)))
				;; Explicit supertypes must precede this declaration and satisfy structural extension rules.
				(if (i32.ne (local.get $super) (i32.const -1))
					(then
						(local.set $super (call $reference-heap (local.get $super)))
						;; The backward supertype constraint also prevents cyclic declared subtype chains.
						(if (i32.ge_u (local.get $super) (local.get $i))
							(then
								(call $fail (i32.const 10))
								(br $done)
							)
						)
						;; Final parents and incompatible field or function signatures reject the declaration.
						(if (i32.eqz (call $heap-extends (local.get $i) (local.get $super)))
							(then
								(call $fail (i32.const 7))
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
	)

	;; Compare one pair of composite members within the currently active recursive group comparison.
	(func $heap-member-equal
		(param $a i32)
		(param $b i32)
		(result i32)
		(local $ha i32)
		(local $hb i32)
		(local $sa i32)
		(local $sb i32)
		(local $i i32)
		(local $fa i32)
		(local $fb i32)

		(local.set $ha (call $heap-record (local.get $a)))
		(local.set $hb (call $heap-record (local.get $b)))
		;; Kind, finality and the existence of a supertype are canonical properties.
		(if
			(i32.or
				(i32.ne (i32.load (local.get $ha)) (i32.load (local.get $hb)))
				(i32.or
					(i32.ne (i32.load offset=12 (local.get $ha)) (i32.load offset=12 (local.get $hb)))
					(i32.ne
						(i32.eq (i32.load offset=16 (local.get $ha)) (i32.const -1))
						(i32.eq (i32.load offset=16 (local.get $hb)) (i32.const -1))
					)
				)
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Declared supertypes compare as heap references in the current group context.
		(if (i32.ne (i32.load offset=16 (local.get $ha)) (i32.const -1))
			(then
				;; Declared parent types must have the same canonical identity.
				(if
					(i32.eqz
						(call $type-equal
							(i32.load offset=16 (local.get $ha))
							(i32.load offset=16 (local.get $hb))
						)
					)
					(then
						(return (i32.const 0))
					)
				)
			)
		)
		;; Function members compare complete parameter and result vectors.
		(if (i32.eqz (i32.load (local.get $ha)))
			(then
				(local.set $sa (call $signature (local.get $a)))
				(local.set $sb (call $signature (local.get $b)))
				;; Parameter arities and ordered result shapes must agree.
				(if
					(i32.or
						(i32.ne (i32.load offset=8 (local.get $sa)) (i32.load offset=8 (local.get $sb)))
						(i32.eqz
							(call $shape-equal
								(i32.load offset=12 (local.get $sa))
								(i32.load offset=12 (local.get $sb))
							)
						)
					)
					(then
						(return (i32.const 0))
					)
				)
				;; Complete after every ordered parameter has matched canonically.
				(block $done
					;; Parameter names do not contribute to canonical type identity.
					(loop $params
						(br_if $done (i32.eq (local.get $i) (i32.load offset=8 (local.get $sa))))
						;; Each parameter must match in its ordered function signature.
						(if
							(i32.eqz
								(call $type-equal
									(i32.load offset=32 (i32.add (local.get $sa) (i32.mul (local.get $i) (i32.const 4))))
									(i32.load offset=32 (i32.add (local.get $sb) (i32.mul (local.get $i) (i32.const 4))))
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
				(return (i32.const 1))
			)
		)
		;; Array and struct members require the same ordered field count.
		(if
			(i32.ne (i32.load offset=24 (local.get $ha)) (i32.load offset=24 (local.get $hb)))
			(then
				(return (i32.const 0))
			)
		)
		;; Finish after every field storage type and mutability has matched.
		(block $done
			;; Field names are annotations and do not affect structural canonicalization.
			(loop $fields
				(br_if $done (i32.eq (local.get $i) (i32.load offset=24 (local.get $ha))))
				(local.set $fa
					(call $field-record (i32.add (i32.load offset=20 (local.get $ha)) (local.get $i)))
				)
				(local.set $fb
					(call $field-record (i32.add (i32.load offset=20 (local.get $hb)) (local.get $i)))
				)
				;; Mutable and immutable storage retain distinct type identities.
				(if
					(i32.or
						(i32.ne (i32.load offset=4 (local.get $fa)) (i32.load offset=4 (local.get $fb)))
						(i32.eqz (call $type-equal (i32.load (local.get $fa)) (i32.load (local.get $fb))))
					)
					(then
						(return (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $fields)
			)
		)
		(i32.const 1)
	)
