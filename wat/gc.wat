	;; Find the common abstract root of a reference hierarchy for cast validation.
	(func $reference-root
		(param $type i32)
		(result i32)
		(local $category i32)

		(local.set $category (call $reference-category (local.get $type)))
		;; Function and external bottoms share their respective abstract roots.
		(if
			(i32.or
				(i32.eq (local.get $category) (i32.const 5))
				(i32.eq (local.get $category) (i32.const 28))
			)
			(then
				(return (i32.const 5))
			)
		)
		;; External references cannot be cast into the internal hierarchy directly.
		(if
			(i32.or
				(i32.eq (local.get $category) (i32.const 6))
				(i32.eq (local.get $category) (i32.const 30))
			)
			(then
				(return (i32.const 6))
			)
		)
		;; Exception references form a separate hierarchy.
		(if
			(i32.or
				(i32.eq (local.get $category) (i32.const 32))
				(i32.eq (local.get $category) (i32.const 34))
			)
			(then
				(return (i32.const 32))
			)
		)
		(i32.const 16)
	)

	;; Validate reference equality, casts, conversions and boxed small integers.
	(func $validate-gc-reference
		(param $op i32)
		(param $target i32)
		(local $type i32)

		;; Equality accepts only equality references, including the internal bottom.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_EQ))
			(then
				(drop (call $validation-pop (i32.const 18)))
				(drop (call $validation-pop (i32.const 18)))
				(call $validation-value (i32.const 1))
				(return)
			)
		)
		;; Tests and casts accept references in the target's abstract hierarchy.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_REF_TEST)) (i32.eq (local.get $op) (i32.const M4_OP_REF_CAST)))
			(then
				;; Numeric target types are malformed reference type immediates.
				(if (i32.eqz (call $is-reference (local.get $target)))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return)
					)
				)
				(drop (call $validation-pop (call $reference-root (local.get $target))))
				(call $validation-value
					(select (i32.const 1) (local.get $target) (i32.eq (local.get $op) (i32.const M4_OP_REF_TEST)))
				)
				(return)
			)
		)
		;; External conversion preserves the nullability of its input.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ANY_CONVERT_EXTERN))
			(then
				(local.set $type (call $validation-pop (i32.const 6)))
				(call $validation-value
					(i32.add (i32.const 16) (call $reference-nonnull (local.get $type)))
				)
				(return)
			)
		)
		;; Converting an internal reference back to extern also preserves nullability.
		(if (i32.eq (local.get $op) (i32.const M4_OP_EXTERN_CONVERT_ANY))
			(then
				(local.set $type (call $validation-pop (i32.const 16)))
				(call $validation-value
					(select (i32.const 9) (i32.const 6) (call $reference-nonnull (local.get $type)))
				)
				(return)
			)
		)
		;; Small integer construction consumes i32 and produces a non-null i31 reference.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_I31))
			(then
				(drop (call $validation-pop (i32.const 1)))
				(call $validation-value (i32.const 21))
				(return)
			)
		)
		(drop (call $validation-pop (i32.const 20)))
		(call $validation-value (i32.const 1))
	)

	;; Test a runtime reference against a complete target reference type.
	(func $runtime-reference-matches
		(param $value i64)
		(param $target i32)
		(result i32)

		;; Null matches only nullable targets, including bottom reference types.
		(if (i64.eqz (local.get $value))
			(then
				(return (i32.eqz (call $reference-nonnull (local.get $target))))
			)
		)
		;; Function references carry a source function index plus one.
		(if (i32.eq (call $reference-root (local.get $target)) (i32.const 5))
			(then
				(return
					(call $type-compatible
						(call $function-reference-type (i32.sub (i32.wrap_i64 (local.get $value)) (i32.const 1)))
						(local.get $target)
					)
				)
			)
		)
		;; External targets accept every non-null value in the external hierarchy.
		(if (i32.eq (call $reference-root (local.get $target)) (i32.const 6))
			(then
				(return (call $type-compatible (i32.const 9) (local.get $target)))
			)
		)
		;; Tagged small integers retain all 31 payload bits in the low word.
		(if (i64.ne (i64.and (local.get $value) (i64.const 2147483648)) (i64.const 0))
			(then
				(return (call $type-compatible (i32.const 21) (local.get $target)))
			)
		)
		;; Aggregate handles carry their allocation's precise declared heap type.
		(if (i64.ne (i64.and (local.get $value) (i64.const 1073741824)) (i64.const 0))
			(then
				(return
					(call $type-compatible
						(call $intern-reference-type
							(i32.load (call $gc-object (local.get $value)))
							(i32.const 0)
							(global.get $tok)
							(i32.const 1)
						)
						(local.get $target)
					)
				)
			)
		)
		(call $type-compatible (i32.const 17) (local.get $target))
	)

	;; Execute pure reference operations using interpreter-owned tagged values.
	(func $gc-reference-apply
		(param $op i32)
		(param $a i64)
		(param $b i64)
		(param $target i32)
		(result i64)

		;; Identity comparison includes null and separately allocated references.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_EQ))
			(then
				(return (i64.extend_i32_u (i64.eq (local.get $a) (local.get $b))))
			)
		)
		;; Tests return an ordinary i32 Boolean without trapping on null.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_TEST))
			(then
				(return
					(i64.extend_i32_u (call $runtime-reference-matches (local.get $a) (local.get $target)))
				)
			)
		)
		;; Failed casts trap before the value can flow into the refined result type.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_CAST))
			(then
				;; Nullability and declared heap subtyping both participate in the runtime check.
				(if (i32.eqz (call $runtime-reference-matches (local.get $a) (local.get $target)))
					(then
						(call $fail (i32.const M4_ERR_CAST_FAILURE))
					)
				)
			)
		)
		;; Internalizing an opaque external value retains its identity through an explicit wrapper tag.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ANY_CONVERT_EXTERN))
			(then
				;; Null and previously externalized internal values keep their original representation.
				(if
					(i32.or
						(i64.eqz (local.get $a))
						(i64.ne (i64.and (local.get $a) (i64.const 3221225472)) (i64.const 0))
					)
					(then
						(return (local.get $a))
					)
				)
				(return (i64.or (local.get $a) (i64.const 536870912)))
			)
		)
		;; Externalizing a wrapper restores its original opaque external handle.
		(if (i32.eq (local.get $op) (i32.const M4_OP_EXTERN_CONVERT_ANY))
			(then
				(return (i64.and (local.get $a) (i64.const 3758096383)))
			)
		)
		;; Box a small integer by setting its dedicated tag bit after truncating to 31 bits.
		(if (i32.eq (local.get $op) (i32.const M4_OP_REF_I31))
			(then
				(return (i64.or (i64.and (local.get $a) (i64.const 2147483647)) (i64.const 2147483648)))
			)
		)
		;; Both small integer projections reject null and differ only in sign extension.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_I31_GET_S))
			(then
				;; Null has no small-integer payload.
				(if (i64.eqz (local.get $a))
					(then
						(call $fail (i32.const M4_ERR_NULL_REFERENCE))
						(return (i64.const 0))
					)
				)
				;; Signed projection extends bit 30 through the i32 sign bit.
				(if (i32.eq (local.get $op) (i32.const M4_OP_I31_GET_S))
					(then
						(return
							(i64.extend_i32_s
								(i32.shr_s (i32.shl (i32.wrap_i64 (local.get $a)) (i32.const 1)) (i32.const 1))
							)
						)
					)
				)
				(return (i64.and (local.get $a) (i64.const 2147483647)))
			)
		)
		(local.get $a)
	)

	;; Parse late-bound aggregate type and field or secondary index operands into a private descriptor.
	(func $gc-immediate
		(param $op i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $new-memory-immediate))
		;; Array length has no declared type immediate.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_LEN))
			(then
				(return (local.get $record))
			)
		)
		(i32.store (local.get $record) (call $reference-type))
		;; Struct access accepts either a numeric field index or a source-backed field name.
		(if
			(i32.and
				(i32.ge_u (local.get $op) (i32.const M4_OP_STRUCT_GET))
				(i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_SET))
			)
			(then
				(i32.store offset=4 (local.get $record) (call $function-reference))
				(i32.store offset=8 (local.get $record) (global.get $immediate-length))
			)
		)
		;; Fixed arrays carry an explicit element count.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
			(then
				(i32.store offset=4 (local.get $record) (call $index))
			)
		)
		;; Array copy names its source array type independently from the destination type.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_COPY))
			(then
				(i32.store offset=4 (local.get $record) (call $reference-type))
			)
		)
		;; Data and element operations retain a separate segment index namespace.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DATA)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_ELEM)))
				(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_INIT_DATA))
			)
			(then
				(i32.store offset=4 (local.get $record) (call $function-reference))
				(i32.store offset=8 (local.get $record) (global.get $immediate-length))
				(i32.store offset=12 (local.get $record) (global.get $tok))
			)
		)
		(local.get $record)
	)

	;; Convert a storage-only packed field type to its ordinary operand type.
	(func $unpacked-type
		(param $type i32)
		(result i32)

		(select
			(i32.const 1)
			(local.get $type)
			(i32.or
				(i32.eq (local.get $type) (i32.const 12))
				(i32.eq (local.get $type) (i32.const 13))
			)
		)
	)

	;; Resolve a struct field name or numeric index without accessing beyond its declared fields.
	(func $gc-field
		(param $heap i32)
		(param $immediate i32)
		(result i32)
		(local $index i32)
		(local $count i32)
		(local $base i32)
		(local $field i32)

		(local.set $count (i32.load offset=24 (call $heap-record (local.get $heap))))
		(local.set $base (i32.load offset=20 (call $heap-record (local.get $heap))))
		(local.set $index (i32.load offset=4 (local.get $immediate)))
		;; Named fields are local to the selected struct declaration.
		(if (i32.load offset=8 (local.get $immediate))
			(then
				(local.set $index (i32.const 0))
				;; Search the ordered field vector and stop at its first exact identifier match.
				(block $found
					;; A missing name reaches the count and triggers the same bounds error as a numeric index.
					(loop $fields
						(br_if $found (i32.eq (local.get $index) (local.get $count)))
						(local.set $field (call $field-record (i32.add (local.get $base) (local.get $index))))
						(br_if $found
							;; Compare bytes only after the complete span/prefix guard succeeds.
							(if (result i32)
								(i32.eq
									(i32.load offset=8 (local.get $immediate))
									(i32.load offset=12 (local.get $field))
								)
								(then
									(call $equal
										(i32.load offset=4 (local.get $immediate))
										(i32.load offset=8 (local.get $field))
										(i32.load offset=12 (local.get $field))
									)
								)
								;; An incompatible span cannot match this name or prefix.
								(else (i32.const 0))
							)
						)
						(local.set $index (i32.add (local.get $index) (i32.const 1)))
						(br $fields)
					)
				)
			)
		)
		;; Every field access must stay within the declared struct type.
		(if (i32.ge_u (local.get $index) (local.get $count))
			(then
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
			)
		)
		(i32.store offset=4 (local.get $immediate) (local.get $index))
		(i32.store offset=8 (local.get $immediate) (i32.const 0))
		(call $field-record (i32.add (local.get $base) (local.get $index)))
	)

	;; Allocate a stable-address object, collecting unreachable blocks before reporting exhaustion.
	(func $gc-allocate
		(param $heap i32)
		(param $count i32)
		(param $clear i32)
		(result i32)
		(local $size i64)
		(local $object i32)

		(local.set $size (i64.add (i64.const M4_GC_HEADER_BYTES)
			(i64.mul (i64.extend_i32_u (local.get $count)) (i64.const M4_GC_SLOT_BYTES))))
		;; An individually oversized allocation cannot benefit from collection.
		(if (i64.gt_u (local.get $size) (i64.const M4_GC_ARENA_BYTES))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		(local.set $object (call $gc-take (i32.wrap_i64 (local.get $size))))
		;; Retry only after all guest, host and native-constructor roots have been traced.
		(if (i32.eqz (local.get $object))
			(then
				(call $gc-collect)
				(local.set $object (call $gc-take (i32.wrap_i64 (local.get $size))))
			)
		)
		;; A full live heap or fragmented surviving allocations retain the normal resource failure.
		(if (i32.eqz (local.get $object))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		;; Constructors that evaluate nested expressions must begin with null reference fields.
		(if (local.get $clear)
			(then (call $zero-bytes (i32.add (local.get $object) (i32.const M4_GC_HEADER_BYTES))
				(i32.sub (i32.wrap_i64 (local.get $size)) (i32.const M4_GC_HEADER_BYTES))))
		)
		(i32.store (local.get $object) (local.get $heap))
		(i32.store offset=4 (local.get $object) (local.get $count))
		(i32.store offset=8 (local.get $object) (i32.const 0))
		(local.get $object)
	)

	;; Encode an arena address into a compact reference that also fits table slots.
	(func $gc-reference
		(param $object i32)
		(result i64)

		(i64.extend_i32_u
			(i32.or (i32.const 1073741824) (i32.sub (local.get $object) (global.get $gc-object-base)))
		)
	)

	;; Decode an aggregate reference and report a guest null trap before reading its header.
	(func $gc-object
		(param $reference i64)
		(result i32)

		;; Null cannot be dereferenced as an aggregate object.
		(if (i64.eqz (local.get $reference))
			(then
				(call $fail (i32.const M4_ERR_NULL_REFERENCE))
				(return (global.get $gc-object-base))
			)
		)
		(i32.add
			(global.get $gc-object-base)
			(i32.and (i32.wrap_i64 (local.get $reference)) (i32.const 1073741823))
		)
	)

	;; Locate one sixteen-byte raw field slot within an allocated object.
	(func $gc-slot
		(param $object i32)
		(param $index i32)
		(result i32)

		(i32.add
			(local.get $object)
			(i32.add (i32.const 16) (i32.mul (local.get $index) (i32.const 16)))
		)
	)

	;; Pop one runtime operand while retaining its separate vector high half.
	(func $gc-pop
		(result i64)

		(global.set $sp (i32.sub (global.get $sp) (i32.const 1)))
		(global.set $gc-high
			(i64.load
				(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
			)
		)
		(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
	)

	;; Store a field using its packed width or complete scalar/vector raw representation.
	(func $gc-store
		(param $slot i32)
		(param $type i32)
		(param $value i64)
		(param $high i64)

		;; Packed i8 storage truncates only at field assignment.
		(if (i32.eq (local.get $type) (i32.const 12))
			(then
				(local.set $value (i64.and (local.get $value) (i64.const 255)))
			)
		)
		;; Packed i16 storage has a distinct truncation mask.
		(if (i32.eq (local.get $type) (i32.const 13))
			(then
				(local.set $value (i64.and (local.get $value) (i64.const 65535)))
			)
		)
		(i64.store (local.get $slot) (local.get $value))
		(i64.store offset=8 (local.get $slot) (local.get $high))
	)

	;; Repeat one normalized raw field slot across an already checked array range.
	(func $gc-fill
		(param $slot i32)
		(param $count i32)
		(param $type i32)
		(param $value i64)
		(param $high i64)
		(local $written i32)
		(local $remaining i32)
		(local $copy i32)

		;; Empty ranges must not read or write their end pointer.
		(if (i32.eqz (local.get $count)) (then (return)))
		(call $gc-store (local.get $slot) (local.get $type) (local.get $value) (local.get $high))
		(local.set $written (i32.const 1))
		;; Finish once all slots contain the first slot's complete normalized representation.
		(block $done
			;; Each copy doubles the initialized prefix, with a bounded final partial copy.
			(loop $repeat
				(local.set $remaining (i32.sub (local.get $count) (local.get $written)))
				(br_if $done (i32.eqz (local.get $remaining)))
				(local.set $copy (select (local.get $written) (local.get $remaining)
					(i32.lt_u (local.get $written) (local.get $remaining))))
				(memory.copy
					(i32.add (local.get $slot) (i32.mul (local.get $written) (i32.const M4_GC_SLOT_BYTES)))
					(local.get $slot)
					(i32.mul (local.get $copy) (i32.const M4_GC_SLOT_BYTES)))
				(local.set $written (i32.add (local.get $written) (local.get $copy)))
				(br $repeat)
			)
		)
	)

	;; Validate field-dependent aggregate instructions against their declared composite types.
	(func $validate-gc-aggregate
		(param $op i32)
		(param $immediate i32)
		(local $heap i32)
		(local $record i32)
		(local $field i32)
		(local $type i32)
		(local $count i32)
		(local $i i32)
		(local $ref i32)

		;; Array length consumes the abstract array hierarchy without a declared type use.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_LEN))
			(then
				(drop (call $validation-pop (i32.const 24)))
				(call $validation-value (i32.const 1))
				(return)
			)
		)
		(local.set $ref (i32.load (local.get $immediate)))
		;; Composite operator immediates must name concrete type declarations.
		(if (i32.lt_u (local.get $ref) (i32.const 64))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		(local.set $heap (call $reference-heap (local.get $ref)))
		(local.set $record (call $heap-record (local.get $heap)))
		;; Struct and array opcode families require their corresponding composite kind.
		(if
			(i32.ne
				(i32.load (local.get $record))
				(select (i32.const 1) (i32.const 2) (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_SET)))
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(local.set $count (i32.load offset=24 (local.get $record)))
		(local.set $field (call $field-record (i32.load offset=20 (local.get $record))))
		;; Struct construction consumes its ordered field vector in reverse stack order.
		(if (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT))
			(then
				(local.set $i (local.get $count))
				;; Each field is required explicitly or must have a default value.
				(block $done
					;; Validate from the last field back to the first without mutating the declaration.
					(loop $fields
						(br_if $done (i32.eqz (local.get $i)))
						(local.set $i (i32.sub (local.get $i) (i32.const 1)))
						(local.set $type
							(i32.load
								(call $field-record (i32.add (i32.load offset=20 (local.get $record)) (local.get $i)))
							)
						)
						;; Explicit constructors consume values; default constructors require defaultable fields.
						(if (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW))
							(then
								(drop (call $validation-pop (call $unpacked-type (local.get $type))))
							)
							;; Non-null reference fields cannot be zero initialized.
							(else
								;; A non-null element cannot use the zero default value.
								(if
									(i32.and
										(call $is-reference (local.get $type))
										(call $reference-nonnull (local.get $type))
									)
									(then
										(call $fail (i32.const M4_ERR_OPERAND_STACK))
									)
								)
							)
						)
						(br $fields)
					)
				)
				(call $validation-value (call $reference-nonnull-type (local.get $ref)))
				(return)
			)
		)
		;; Struct field access resolves named fields before validating its operand types.
		(if (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_SET))
			(then
				(local.set $field (call $gc-field (local.get $heap) (local.get $immediate)))
			)
		)
		(local.set $type (i32.load (local.get $field)))
		;; Fixed array construction consumes the declared number of element operands.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
			(then
				(local.set $i (i32.load offset=4 (local.get $immediate)))
				;; Element counts cannot exceed the bounded operand stack.
				(if (i32.gt_u (local.get $i) (i32.const M4_CAP_OPERANDS))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
						(return)
					)
				)
				;; Finish after consuming exactly the explicit element count.
				(block $done
					;; Fixed array operands all use the array's unpacked storage type.
					(loop $elements
						(br_if $done (i32.eqz (local.get $i)))
						(drop (call $validation-pop (call $unpacked-type (local.get $type))))
						(local.set $i (i32.sub (local.get $i) (i32.const 1)))
						(br $elements)
					)
				)
				(call $validation-value (call $reference-nonnull-type (local.get $ref)))
				(return)
			)
		)
		;; Dynamic array constructors consume their length followed by an optional repeated element.
		(if
			(i32.and
				(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_NEW))
				(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_NEW_DEFAULT))
			)
			(then
				(drop (call $validation-pop (i32.const 1)))
				;; Repeated element constructors require a typed value.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW))
					(then
						(drop (call $validation-pop (call $unpacked-type (local.get $type))))
					)
					;; Default elements cannot carry non-null reference types.
					(else
						;; Default construction must reject each non-null reference field.
						(if
							(i32.and
								(call $is-reference (local.get $type))
								(call $reference-nonnull (local.get $type))
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
					)
				)
				(call $validation-value (call $reference-nonnull-type (local.get $ref)))
				(return)
			)
		)
		;; Set operations require mutable storage and consume the stored value first.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_SET)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_SET)))
			(then
				;; Immutable aggregate fields cannot be assigned.
				(if (i32.eqz (i32.load offset=4 (local.get $field)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(drop (call $validation-pop (call $unpacked-type (local.get $type))))
				;; Array assignment also consumes an element index.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_SET))
					(then
						(drop (call $validation-pop (i32.const 1)))
					)
				)
				(drop (call $validation-pop (local.get $ref)))
				(return)
			)
		)
		;; Ordinary and signed/unsigned gets distinguish packed from unpacked storage.
		(if
			(i32.or
				(i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_GET_U))
				(i32.and
					(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_GET))
					(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_GET_U))
				)
			)
			(then
				;; A packed field requires a signed or unsigned projection.
				(if
					(i32.ne
						(i32.or
							(i32.eq (local.get $type) (i32.const 12))
							(i32.eq (local.get $type) (i32.const 13))
						)
						(i32.eqz
							(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_GET)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_GET)))
						)
					)
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				;; Array getters consume an index before their array reference.
				(if (i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_GET))
					(then
						(drop (call $validation-pop (i32.const 1)))
					)
				)
				(drop (call $validation-pop (local.get $ref)))
				(call $validation-value (call $unpacked-type (local.get $type)))
				(return)
			)
		)
		;; Segment-backed constructors and initialization validate their independent namespaces.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DATA)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_ELEM)))
				(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_INIT_DATA))
			)
			(then
				(call $gc-resolve-segment (local.get $op) (local.get $immediate) (local.get $type))
				(drop (call $validation-pop (i32.const 1)))
				(drop (call $validation-pop (i32.const 1)))
				;; In-place initialization additionally consumes the destination index and array reference.
				(if (i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_INIT_DATA))
					(then
						;; Only mutable arrays may be initialized after construction.
						(if (i32.eqz (i32.load offset=4 (local.get $field)))
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
						(drop (call $validation-pop (i32.const 1)))
						(drop (call $validation-pop (local.get $ref)))
					)
					;; Constructors produce a fresh precise non-null array reference.
					(else
						(call $validation-value (call $reference-nonnull-type (local.get $ref)))
					)
				)
				(return)
			)
		)
		;; Fill and copy require mutable destination storage and four or five operands.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_FILL)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_COPY)))
			(then
				;; An immutable array cannot receive a bulk write.
				(if (i32.eqz (i32.load offset=4 (local.get $field)))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(drop (call $validation-pop (i32.const 1)))
				;; Copy consumes the source index and source array with a compatible element type.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_COPY))
					(then
						(local.set $i (call $reference-heap (i32.load offset=4 (local.get $immediate))))
						;; Source types must be arrays and their elements must fit destination storage.
						(if (i32.ne (i32.load (call $heap-record (local.get $i))) (i32.const 2))
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
						(local.set $count
							(i32.load (call $field-record (i32.load offset=20 (call $heap-record (local.get $i)))))
						)
						;; Packed storage compatibility retains exact widths; ordinary fields allow subtypes.
						(if (i32.eqz (call $type-compatible (local.get $count) (local.get $type)))
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
						(drop (call $validation-pop (i32.const 1)))
						(drop (call $validation-pop (i32.load offset=4 (local.get $immediate))))
					)
					;; Fill consumes one repeated element value of the unpacked storage type.
					(else
						(drop (call $validation-pop (call $unpacked-type (local.get $type))))
					)
				)
				(drop (call $validation-pop (i32.const 1)))
				(drop (call $validation-pop (local.get $ref)))
				(return)
			)
		)
		(call $fail (i32.const M4_ERR_UNSUPPORTED))
	)

	;; Execute aggregate construction and access directly on the interpreter's object arena.
	(func $gc-aggregate-apply
		(param $op i32)
		(param $immediate i32)
		(result i64)
		(local $heap i32)
		(local $record i32)
		(local $field i32)
		(local $type i32)
		(local $count i32)
		(local $i i32)
		(local $object i32)
		(local $slot i32)
		(local $value i64)
		(local $high i64)

		(global.set $gc-high (i64.const 0))
		;; Array length reads the allocation's dynamic length, independently from its concrete type.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_LEN))
			(then
				(local.set $object (call $gc-object (call $gc-pop)))
				(return (i64.extend_i32_u (i32.load offset=4 (local.get $object))))
			)
		)
		(local.set $heap (call $reference-heap (i32.load (local.get $immediate))))
		(local.set $record (call $heap-record (local.get $heap)))
		(local.set $count (i32.load offset=24 (local.get $record)))
		(local.set $field (call $field-record (i32.load offset=20 (local.get $record))))
		(local.set $type (i32.load (local.get $field)))
		;; Struct constructors allocate one raw slot per declared field.
		(if (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT))
			(then
				(local.set $object (call $gc-allocate (local.get $heap) (local.get $count) (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT))))
				;; Failed allocation must not write fields at address zero or publish a reference.
				(if (global.get $error)
					(then (return (i64.const 0)))
				)
				;; Explicit constructors install fields from the operand stack in reverse order.
				(if (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW))
					(then
						(local.set $i (local.get $count))
						;; Stop after the first field has received its operand.
						(block $done
							;; Preserve complete vectors and truncate packed fields only at storage.
							(loop $fields
								(br_if $done (i32.eqz (local.get $i)))
								(local.set $i (i32.sub (local.get $i) (i32.const 1)))
								(local.set $value (call $gc-pop))
								(call $gc-store
									(call $gc-slot (local.get $object) (local.get $i))
									(i32.load
										(call $field-record (i32.add (i32.load offset=20 (local.get $record)) (local.get $i)))
									)
									(local.get $value)
									(global.get $gc-high)
								)
								(br $fields)
							)
						)
					)
				)
				(global.set $gc-high (i64.const 0))
				(return (call $gc-reference (local.get $object)))
			)
		)
		;; Repeated, default and fixed arrays share one dynamic slot layout.
		(if
			(i32.and
				(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_NEW))
				(i32.le_u (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
			)
			(then
				;; Fixed constructors obtain their count from the immediate rather than an operand.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
					(then
						(local.set $count (i32.load offset=4 (local.get $immediate)))
					)
					;; Dynamic constructors pop an unsigned i32 length.
					(else
						(local.set $count (i32.wrap_i64 (call $gc-pop)))
					)
				)
				;; Repeated elements retain both raw halves across allocation and the fill loop.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW))
					(then
						(local.set $value (call $gc-pop))
						(local.set $high (global.get $gc-high))
					)
				)
				(local.set $object (call $gc-allocate (local.get $heap) (local.get $count) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DEFAULT))))
				;; Allocation failure must not address an unallocated slot range.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Repeated constructors normalize once, then copy complete initialized slots.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW))
					(then
						(call $gc-fill (call $gc-slot (local.get $object) (i32.const 0))
							(local.get $count) (local.get $type) (local.get $value) (local.get $high))
					)
				)
				;; Default constructors already have zeroed slots from allocation; fixed values remain distinct.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
					(then
						(local.set $i (local.get $count))
						;; Stop after the first fixed element has received its operand.
						(block $done
							;; Reverse iteration preserves the fixed constructor's operand order.
							(loop $elements
								(br_if $done (i32.eqz (local.get $i)))
								(local.set $i (i32.sub (local.get $i) (i32.const 1)))
								(local.set $value (call $gc-pop))
								(local.set $high (global.get $gc-high))
								(call $gc-store (call $gc-slot (local.get $object) (local.get $i))
									(local.get $type) (local.get $value) (local.get $high))
								(br $elements)
							)
						)
					)
				)
				(global.set $gc-high (i64.const 0))
				(return (call $gc-reference (local.get $object)))
			)
		)
		;; Segment and bulk operations consume their longer operand vectors in a dedicated helper.
		(if
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DATA)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_ELEM)))
				(i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_FILL))
			)
			(then
				(return
					(call $gc-array-bulk
						(local.get $op)
						(local.get $immediate)
						(local.get $heap)
						(local.get $type)
					)
				)
			)
		)
		;; Struct access resolves its field index during validation.
		(if (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_SET))
			(then
				(local.set $i (i32.load offset=4 (local.get $immediate)))
				(local.set $type
					(i32.load
						(call $field-record (i32.add (i32.load offset=20 (local.get $record)) (local.get $i)))
					)
				)
			)
		)
		;; Set instructions consume the assigned value before the reference and optional index.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_SET)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_SET)))
			(then
				(local.set $value (call $gc-pop))
				(local.set $high (global.get $gc-high))
			)
		)
		;; Array access obtains a dynamic element index from the operand stack.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_GET))
			(then
				(local.set $i (i32.wrap_i64 (call $gc-pop)))
			)
		)
		(local.set $object (call $gc-object (call $gc-pop)))
		;; A null reference trap precedes any bounds check or backing arena access.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		;; Array indexing must be within the allocation's dynamic length.
		(if (i32.ge_u (local.get $i) (i32.load offset=4 (local.get $object)))
			(then
				(call $fail (i32.const M4_ERR_ARRAY_BOUNDS))
				(return (i64.const 0))
			)
		)
		(local.set $slot (call $gc-slot (local.get $object) (local.get $i)))
		;; Mutable field assignment changes the object in place and has no result.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_SET)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_SET)))
			(then
				(call $gc-store (local.get $slot) (local.get $type) (local.get $value) (local.get $high))
				(return (i64.const 0))
			)
		)
		(local.set $value (i64.load (local.get $slot)))
		(global.set $gc-high (i64.load offset=8 (local.get $slot)))
		;; Signed packed gets extend their stored bit width to an ordinary i32.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_GET_S)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_GET_S)))
			(then
				;; Packed byte and halfword projections require different sign-extension shifts.
				(if (i32.eq (local.get $type) (i32.const 12))
					(then
						(return (i64.extend_i32_s (i32.extend8_s (i32.wrap_i64 (local.get $value)))))
					)
					;; Halfword storage extends bit fifteen.
					(else
						(return (i64.extend_i32_s (i32.extend16_s (i32.wrap_i64 (local.get $value)))))
					)
				)
			)
		)
		(local.get $value)
	)

	;; Expose an aggregate value's precise type to trusted raw-result diagnostics.
	(func (export "object_type")
		(param $value i64)
		(result i32)

		(call $intern-reference-type
			(i32.load (call $gc-object (local.get $value)))
			(i32.const 0)
			(global.get $tok)
			(i32.const 1)
		)
	)

	;; Parse a folded struct or array constant with recursively typed field expressions.
	(func $gc-constant-body
		(param $op i32)
		(param $expected i32)
		(result i64)
		(local $immediate i32)
		(local $heap i32)
		(local $record i32)
		(local $object i32)
		(local $count i32)
		(local $i i32)
		(local $type i32)
		(local $value i64)
		(local $high i64)

		(call $next)
		(local.set $immediate (call $gc-immediate (local.get $op)))
		(local.set $heap (call $reference-heap (i32.load (local.get $immediate))))
		(local.set $record (call $heap-record (local.get $heap)))
		;; Only constructors of the corresponding composite kind are constant expressions.
		(if
			(i32.ne
				(i32.load (local.get $record))
				(select (i32.const 1) (i32.const 2) (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT)))
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return (i64.const 0))
			)
		)
		;; Construction yields a precise non-null reference compatible with the declared result.
		(if
			(i32.eqz
				(call $type-compatible
					(call $reference-nonnull-type (i32.load (local.get $immediate)))
					(local.get $expected)
				)
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
			)
		)
		(local.set $count (i32.load offset=24 (local.get $record)))
		(local.set $type (i32.load (call $field-record (i32.load offset=20 (local.get $record)))))
		;; Dynamic array constructors evaluate a repeated element before their length expression.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW))
			(then
				(local.set $value (call $global-initializer (call $unpacked-type (local.get $type))))
				(local.set $high (global.get $initializer-high))
				;; Repeated reference elements remain live while the length expression allocates.
				(if (call $is-reference (local.get $type))
					(then (i64.store (i32.add (global.get $gc-temp-base)
						(i32.mul (i32.sub (global.get $gc-temp-count) (i32.const 2)) (i32.const 8))) (local.get $value)))
				)
			)
		)
		;; Array length is either a fixed immediate or an i32 constant expression.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_NEW))
			(then
				;; Fixed constructors preserve their explicit element count.
				(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED))
					(then
						(local.set $count (i32.load offset=4 (local.get $immediate)))
					)
					;; Dynamic lengths are computed before allocating backing slots.
					(else
						(local.set $count (i32.wrap_i64 (call $global-initializer (i32.const 1))))
					)
				)
			)
		)
		(local.set $object (call $gc-allocate (local.get $heap) (local.get $count) (i32.const 1)))
		;; The partially initialized parent is rooted before evaluating any nested field expression.
		(i64.store (i32.add (global.get $gc-temp-base)
			(i32.mul (i32.sub (global.get $gc-temp-count) (i32.const 1)) (i32.const 8)))
			(call $gc-reference (local.get $object)))
		;; Allocation failure preserves the first resource error.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		;; Populate fields in expression order rather than runtime reverse stack order.
		(block $done
			;; Defaults stay zero and must be permitted by each declared storage type.
			(loop $fields
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; Struct fields have individual types; arrays repeat their single storage type.
				(if (i32.le_u (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT))
					(then
						(local.set $type
							(i32.load
								(call $field-record (i32.add (i32.load offset=20 (local.get $record)) (local.get $i)))
							)
						)
					)
				)
				;; Explicit struct and fixed-array constructors evaluate one expression per field.
				(if
					(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_FIXED)))
					(then
						(local.set $value (call $global-initializer (call $unpacked-type (local.get $type))))
						(local.set $high (global.get $initializer-high))
					)
				)
				;; Default construction rejects fields with a non-null reference type.
				(if
					(i32.or (i32.eq (local.get $op) (i32.const M4_OP_STRUCT_NEW_DEFAULT)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DEFAULT)))
					(then
						;; A zero reference is valid only for nullable storage.
						(if
							(i32.and
								(call $is-reference (local.get $type))
								(call $reference-nonnull (local.get $type))
							)
							(then
								(call $fail (i32.const M4_ERR_OPERAND_STACK))
							)
						)
					)
				)
				(call $gc-store
					(call $gc-slot (local.get $object) (local.get $i))
					(local.get $type)
					(local.get $value)
					(local.get $high)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $fields)
			)
		)
		(call $expect (i32.const 2))
		(global.set $initializer-high (i64.const 0))
		(global.set $initializer-function-present (i32.const 0))
		(call $gc-reference (local.get $object))
	)

	;; Return the byte width of a numeric or packed array element used by data segment operations.
	(func $gc-storage-width
		(param $type i32)
		(result i32)

		;; Byte and halfword packed storage have explicit widths.
		(if (i32.eq (local.get $type) (i32.const 12))
			(then
				(return (i32.const 1))
			)
		)
		;; Packed halfwords occupy two bytes.
		(if (i32.eq (local.get $type) (i32.const 13))
			(then
				(return (i32.const 2))
			)
		)
		(select
			(i32.const 16)
			(select
				(i32.const 8)
				(i32.const 4)
				(i32.or (i32.eq (local.get $type) (i32.const 2)) (i32.eq (local.get $type) (i32.const 4)))
			)
			(i32.eq (local.get $type) (i32.const 7))
		)
	)

	;; Resolve data or element segment names and check their content against array storage.
	(func $gc-resolve-segment
		(param $op i32)
		(param $immediate i32)
		(param $type i32)
		(local $index i32)

		;; Data-backed arrays require numeric storage rather than reference elements.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DATA)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_INIT_DATA)))
			(then
				;; References cannot be reconstructed from arbitrary data bytes.
				(if (call $is-reference (local.get $type))
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
				(local.set $index
					(call $data-target
						(i32.load offset=4 (local.get $immediate))
						(i32.load offset=8 (local.get $immediate))
					)
				)
			)
			;; Element segments must supply reference values compatible with destination storage.
			(else
				(local.set $index
					(call $element-target
						(i32.load offset=4 (local.get $immediate))
						(i32.load offset=8 (local.get $immediate))
					)
				)
				;; Segment type compatibility is validated even for zero-length initialization.
				(if
					(i32.eqz
						(call $type-compatible
							(i32.load offset=48 (call $element-record (local.get $index)))
							(local.get $type)
						)
					)
					(then
						(call $fail (i32.const M4_ERR_OPERAND_STACK))
					)
				)
			)
		)
		(i32.store offset=4 (local.get $immediate) (local.get $index))
		(i32.store offset=8 (local.get $immediate) (i32.const 0))
	)

	;; Bounds-check an unsigned array range without wrapping its end index.
	(func $gc-array-range
		(param $object i32)
		(param $index i32)
		(param $count i32)

		;; Addition occurs in i64 so overflowing i32 ranges are rejected reliably.
		(if
			(i64.gt_u
				(i64.add (i64.extend_i32_u (local.get $index)) (i64.extend_i32_u (local.get $count)))
				(i64.extend_i32_u (i32.load offset=4 (local.get $object)))
			)
			(then
				(call $fail (i32.const M4_ERR_ARRAY_BOUNDS))
			)
		)
	)

	;; Copy checked numeric segment bytes into complete raw array slots without altering their bits.
	(func $gc-data
		(param $dest i32)
		(param $source i32)
		(param $count i32)
		(param $width i32)
		(local $value i64)

		;; Empty source/destination end pointers require no memory access.
		(if (i32.eqz (local.get $count)) (then (return)))
		;; Vector elements already have exactly the complete raw slot's contiguous layout.
		(if (i32.eq (local.get $width) (i32.const M4_GC_SLOT_BYTES))
			(then
				(memory.copy (local.get $dest) (local.get $source)
					(i32.mul (local.get $count) (i32.const M4_GC_SLOT_BYTES)))
				(return)
			)
		)
		;; Read only each element's checked source width; full stores also clear all slot padding.
		(loop $elements
			(local.set $value
				;; Eight-byte elements retain their raw integer or floating-point representation.
				(if (result i64) (i32.eq (local.get $width) (i32.const M4_DOUBLEWORD_BYTES))
					(then (i64.load (local.get $source)))
					;; Smaller elements widen their bytes with zero padding, never reading a following element.
					(else
						(i64.extend_i32_u
							;; Four-byte scalar bits use a full word load.
							(if (result i32) (i32.eq (local.get $width) (i32.const M4_WORD_BYTES))
								(then (i32.load (local.get $source)))
								;; Packed fields load exactly one or two bytes.
								(else
									;; Halfwords keep both packed bytes.
									(if (result i32) (i32.eq (local.get $width) (i32.const M4_HALFWORD_BYTES))
										(then (i32.load16_u (local.get $source)))
										;; The remaining validated numeric width is one byte.
										(else (i32.load8_u (local.get $source)))
									)
								)
							)
						)
					)
				)
			)
			(i64.store (local.get $dest) (local.get $value))
			(i64.store offset=M4_VECTOR_HIGH_OFFSET (local.get $dest) (i64.const 0))
			(local.set $dest (i32.add (local.get $dest) (i32.const M4_GC_SLOT_BYTES)))
			(local.set $source (i32.add (local.get $source) (local.get $width)))
			(local.set $count (i32.sub (local.get $count) (i32.const 1)))
			(br_if $elements (local.get $count))
		)
	)

	;; Execute segment-backed array creation, initialization, fill and overlapping copy.
	(func $gc-array-bulk
		(param $op i32)
		(param $immediate i32)
		(param $heap i32)
		(param $type i32)
		(result i64)
		(local $count i32)
		(local $source-index i32)
		(local $dest-index i32)
		(local $source i32)
		(local $dest i32)
		(local $segment i32)
		(local $width i32)
		(local $i i32)
		(local $slot i32)
		(local $value i64)
		(local $high i64)

		(local.set $count (i32.wrap_i64 (call $gc-pop)))
		;; Fill reads its repeated value; other operations read a source index or byte offset.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_FILL))
			(then
				(local.set $value (call $gc-pop))
				(local.set $high (global.get $gc-high))
			)
			;; Segment and array copy source indices are unsigned i32 operands.
			(else
				(local.set $source-index (i32.wrap_i64 (call $gc-pop)))
			)
		)
		;; Array copy additionally consumes a source array reference.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_COPY))
			(then
				(local.set $source (call $gc-object (call $gc-pop)))
			)
		)
		;; In-place operations consume the destination index and reference after their source operands.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_ARRAY_FILL))
			(then
				(local.set $dest-index (i32.wrap_i64 (call $gc-pop)))
				(local.set $dest (call $gc-object (call $gc-pop)))
				;; Null traps take precedence over range traps.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(call $gc-array-range (local.get $dest) (local.get $dest-index) (local.get $count))
			)
		)
		;; Array copy checks both ranges before changing any slot, including zero-length copies.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_COPY))
			(then
				(call $gc-array-range (local.get $source) (local.get $source-index) (local.get $count))
				;; Bounds failures prevent partially copied objects.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				(memory.copy
					(call $gc-slot (local.get $dest) (local.get $dest-index))
					(call $gc-slot (local.get $source) (local.get $source-index))
					(i32.mul (local.get $count) (i32.const 16))
				)
				(return (i64.const 0))
			)
		)
		;; Fill checks bounds before repeating a stored value across destination slots.
		(if (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_FILL))
			(then
				;; A rejected range must not enter the write loop.
				(if (global.get $error)
					(then
						(return (i64.const 0))
					)
				)
				;; Normalize the repeated value only after the entire destination range passes.
				(call $gc-fill (call $gc-slot (local.get $dest) (local.get $dest-index))
					(local.get $count) (local.get $type) (local.get $value) (local.get $high))
				(return (i64.const 0))
			)
		)
		;; Data and element segments have distinct range units and trap categories.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_DATA)) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_INIT_DATA)))
			(then
				(local.set $segment (call $data-record (i32.load offset=4 (local.get $immediate))))
				(local.set $width (call $gc-storage-width (local.get $type)))
				;; A data source range is measured in bytes after widening count times element width.
				(if
					(i64.gt_u
						(i64.add
							(i64.extend_i32_u (local.get $source-index))
							(i64.mul (i64.extend_i32_u (local.get $count)) (i64.extend_i32_u (local.get $width)))
						)
						(i64.extend_i32_u (i32.load offset=44 (local.get $segment)))
					)
					(then
						(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
					)
				)
				(local.set $source
					(i32.add (global.get $data-base) (i32.load offset=4 (local.get $segment)))
				)
			)
			;; An element source range is measured in entries, each retaining reference identity.
			(else
				(local.set $segment (call $element-record (i32.load offset=4 (local.get $immediate))))
				;; Dropped and active segments expose only their remaining element count.
				(if
					(i64.gt_u
						(i64.add
							(i64.extend_i32_u (local.get $source-index))
							(i64.extend_i32_u (local.get $count))
						)
						(i64.extend_i32_u (i32.load offset=44 (local.get $segment)))
					)
					(then
						(call $fail (i32.const M4_ERR_ELEMENT_BOUNDS))
					)
				)
				(local.set $source
					(i32.add
						(global.get $element-entry-base)
						(i32.mul (i32.load offset=4 (local.get $segment)) (i32.const 16))
					)
				)
			)
		)
		;; Source and destination bounds must pass before allocating or modifying an object.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		;; Constructor variants allocate their destination only after checking the complete source range.
		(if (i32.lt_u (local.get $op) (i32.const M4_OP_ARRAY_FILL))
			(then
				(local.set $dest (call $gc-allocate (local.get $heap) (local.get $count) (i32.eq (local.get $op) (i32.const M4_OP_ARRAY_NEW_ELEM))))
			)
		)
		;; A resource failure cannot publish an invalid aggregate handle.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		;; Deferred element constructors can allocate while the destination is only in a native local.
		(call $gc-temp-push (call $gc-reference (local.get $dest)))
		;; Numeric segment bytes use exact-width loads or one contiguous vector copy.
		(if (local.get $width)
			(then
				(call $gc-data (call $gc-slot (local.get $dest) (local.get $dest-index))
					(i32.add (local.get $source) (local.get $source-index))
					(local.get $count) (local.get $width))
			)
			;; Element segments retain their live reference decoding and identity.
			(else
				;; Finish once every reference has reached its destination slot.
				(block $done
					;; Each entry resolves its current function or object reference independently.
					(loop $elements
						(br_if $done (i32.eq (local.get $i) (local.get $count)))
						(local.set $slot (call $gc-slot (local.get $dest)
							(i32.add (local.get $dest-index) (local.get $i))))
						(i64.store
							(local.get $slot)
							(i64.extend_i32_u
								(i32.add
									(i32.const 1)
									(call $element-value
										(i32.add
											(local.get $source)
											(i32.mul (i32.add (local.get $source-index) (local.get $i)) (i32.const 16))
										)
									)
								)
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $elements)
					)
				)
			)
		)
		(global.set $gc-temp-count (i32.sub (global.get $gc-temp-count) (i32.const 1)))
		(global.set $gc-high (i64.const 0))
		(select
			(call $gc-reference (local.get $dest))
			(i64.const 0)
			(i32.lt_u (local.get $op) (i32.const M4_OP_ARRAY_FILL))
		)
	)

	;; Remove null from a fallthrough source type when a nullable cast target captures every null value.
	(func $gc-reference-difference
		(param $source i32)
		(param $target i32)
		(result i32)

		(select
			(local.get $source)
			(call $reference-nonnull-type (local.get $source))
			(call $reference-nonnull (local.get $target))
		)
	)

	;; Validate a cast branch's label vector while preserving its declared prefix on fallthrough.
	(func $validate-gc-branch
		(param $op i32)
		(param $immediate i32)
		(local $source i32)
		(local $target i32)
		(local $label i32)
		(local $branch i32)
		(local $fallthrough i32)
		(local $i i32)

		(local.set $source (i32.load offset=4 (local.get $immediate)))
		(local.set $target (i32.load offset=8 (local.get $immediate)))
		;; Cast branches require reference immediates and a target subtype of the declared source.
		(if
			(i32.eqz
				(i32.and
					(i32.and
						(call $is-reference (local.get $source))
						(call $is-reference (local.get $target))
					)
					(call $type-compatible (local.get $target) (local.get $source))
				)
			)
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
			)
		)
		(drop (call $validation-pop (local.get $source)))
		(local.set $label (call $label-arity (i32.load (local.get $immediate))))
		;; A transferred reference must have a final slot in the destination label vector.
		(if (i32.eqz (call $shape-count (local.get $label)))
			(then
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
				(return)
			)
		)
		(local.set $branch
			(select
				(local.get $target)
				(call $gc-reference-difference (local.get $source) (local.get $target))
				(i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST))
			)
		)
		(local.set $fallthrough
			(select
				(call $gc-reference-difference (local.get $source) (local.get $target))
				(local.get $target)
				(i32.eq (local.get $op) (i32.const M4_OP_BR_ON_CAST))
			)
		)
		(call $validation-value (local.get $branch))
		(call $validation-result (local.get $label))
		;; Restore the declared branch prefix, excluding the reference that is refined separately.
		(block $done
			;; Branch operand types become the label's declared types on fallthrough.
			(loop $prefix
				(br_if $done
					(i32.ge_u (i32.add (local.get $i) (i32.const 1)) (call $shape-count (local.get $label)))
				)
				(call $validation-value (call $shape-type (local.get $label) (local.get $i)))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $prefix)
			)
		)
		(call $validation-value (local.get $fallthrough))
	)
