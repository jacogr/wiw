	;; Identify instructions whose pre-operation operand types are needed at a collection boundary.
	(func $gc-map-op
		(param $op i32)
		(result i32)
		(i32.or
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL))
				(i32.eq (local.get $op) (i32.const M4_OP_CALL_INDIRECT)))
			(i32.or
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_CALL_REF))
					(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_RETURN_CALL)) (i32.const 1)))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_RETURN_CALL_REF))
					(i32.or (i32.eq (local.get $op) (i32.const M4_OP_THROW))
						(i32.or
							(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_STRUCT_NEW)) (i32.const 1))
							(i32.le_u (i32.sub (local.get $op) (i32.const M4_OP_ARRAY_NEW))
								(i32.const m4_eval(M4_OP_ARRAY_NEW_ELEM-M4_OP_ARRAY_NEW))))))))
	)

	;; Save a compact list of reference operand indices from the validator's exact type stack.
	(func $gc-build-map
		(param $pc i32)
		(local $i i32)
		(local $count i32)
		(local $map i32)
		(local $end i32)
		(local.set $map (i32.add (global.get $gc-map-base) (global.get $gc-map-used)))
		(local.set $end (i32.add (global.get $gc-map-base) (global.get $gc-map-limit)))
		;; Empty maps require no storage, including the numeric-only interpreter's own call sites.
		(block $done
			;; Each reference position fits an unsigned sixteen-bit index within the operand bound.
			(loop $slots
				(br_if $done (i32.eq (local.get $i) (global.get $depth)))
				;; Only reference types contribute roots; vectors and scalars remain untraced.
				(if (call $is-reference (i32.load (i32.add (global.get $type-stack-base) (i32.shl (local.get $i) (i32.const 2)))))
					(then
						;; A map is committed only when every position fits in its private arena.
						(if (i32.gt_u (i32.add (local.get $map) (i32.add (i32.const 4) (i32.shl (local.get $count) (i32.const 1)))) (local.get $end))
							(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return))
						)
						(i32.store16
							(i32.add
								(local.get $map)
								(i32.add (i32.const 2) (i32.shl (local.get $count) (i32.const 1)))
							)
							(local.get $i)
						)
						(local.set $count (i32.add (local.get $count) (i32.const 1)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $slots)
			)
		)
		;; Zero-reference sites retain their already cleared index entry.
		(if (local.get $count)
			(then
				(i32.store16 (local.get $map) (local.get $count))
				(i32.store
					(i32.add (global.get $gc-map-index-base) (i32.shl (local.get $pc) (i32.const 2)))
					(local.get $map)
				)
				(global.set $gc-map-used
					(i32.add
						(global.get $gc-map-used)
						(i32.shl (i32.add (local.get $count) (i32.const 1)) (i32.const 1))
					)
				)
			)
		)
	)

	;; Record the live call chain and complete operand range before an allocating opcode pops values.
	(func $gc-snapshot
		(param $calls i32)
		(param $record i32)
		(global.set $gc-calls (local.get $calls))
		(global.set $gc-pc
			(i32.shr_u (i32.sub (local.get $record) (global.get $code-base)) (i32.const M4_INSTRUCTION_SHIFT))
		)
		(global.set $gc-stack-end (global.get $sp))
	)

	;; Protect a native constructor local across nested constant-expression allocations.
	(func $gc-temp-push
		(param $value i64)
		;; The parser's bounded nesting reserves two slots per constructor plus bulk-operation slack.
		(if (i32.ge_u (global.get $gc-temp-count) (global.get $gc-temp-limit))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return))
		)
		(i64.store
			(i32.add (global.get $gc-temp-base) (i32.shl (global.get $gc-temp-count) (i32.const 3)))
			(local.get $value)
		)
		(global.set $gc-temp-count (i32.add (global.get $gc-temp-count) (i32.const 1)))
	)

	;; Restore the native root stack on every constant-construction return, including syntax and allocation errors.
	(func $gc-constant
		(param $op i32)
		(param $expected i32)
		(result i64)
		(local $base i32)
		(local $value i64)
		(local.set $base (global.get $gc-temp-count))
		;; Reserve both slots atomically so a failing second push cannot corrupt a parent's roots.
		(if (i32.gt_u (i32.add (local.get $base) (i32.const 2)) (global.get $gc-temp-limit))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i64.const 0)))
		)
		(call $gc-temp-push (i64.const 0))
		(call $gc-temp-push (i64.const 0))
		(local.set $value (call $gc-constant-body (local.get $op) (local.get $expected)))
		(global.set $gc-temp-count (local.get $base))
		(local.get $value)
	)

	;; Allocate from the high-water tail or split a suitably sized free block without moving live objects.
	(func $gc-take
		(param $size i32)
		(result i32)
		(local $object i32)
		(local $previous i32)
		(local $block i32)
		(local $rest i32)
		(local $next i32)
		;; The common bump path needs no free-list traversal or tracing work.
		(if (i32.le_u (local.get $size) (i32.sub (global.get $gc-heap-limit) (global.get $gc-object-used)))
			(then
				(local.set $object (i32.add (global.get $gc-object-base) (global.get $gc-object-used)))
				(global.set $gc-object-used (i32.add (global.get $gc-object-used) (local.get $size)))
			)
			;; At the arena end, reuse swept holes before requesting another collection.
			(else
				(local.set $object (global.get $gc-free))
				(block $found
					;; Exhausting the free list returns zero so the caller can collect and retry.
					(loop $blocks
						(br_if $found (i32.eqz (local.get $object)))
						(local.set $block
							(i32.and
								(i32.load offset=M4_GC_FLAGS_OFFSET (local.get $object))
								(i32.const M4_GC_SIZE_MASK)
							)
						)
						;; Aligned blocks split only on object-header boundaries.
						(if (i32.ge_u (local.get $block) (local.get $size))
							(then
								(local.set $next (i32.load (local.get $object)))
								;; Exact fits disappear; larger blocks leave a new free header at their tail.
								(if (i32.gt_u (local.get $block) (local.get $size))
									(then
										(local.set $rest (i32.add (local.get $object) (local.get $size)))
										(i32.store (local.get $rest) (local.get $next))
										(i32.store offset=M4_GC_FLAGS_OFFSET
											(local.get $rest)
											(i32.or
												(i32.sub (local.get $block) (local.get $size))
												(i32.const M4_GC_FREE)
											)
										)
										(local.set $next (local.get $rest))
									)
								)
								;; Relink either the preceding free block or the list head.
								(if (local.get $previous)
									(then (i32.store (local.get $previous) (local.get $next)))
									(else (global.set $gc-free (local.get $next)))
								)
								(br $found)
							)
						)
						(local.set $previous (local.get $object))
						(local.set $object (i32.load (local.get $object)))
						(br $blocks)
					)
				)
			)
		)
		;; Allocated blocks carry their byte length in the unused header word, with flags initially clear.
		(if (local.get $object)
			(then
				(i32.store offset=M4_GC_FLAGS_OFFSET (local.get $object) (local.get $size))
				(global.set $gc-live (i32.add (global.get $gc-live) (local.get $size)))
			)
		)
		(local.get $object)
	)

	;; Recognize internal aggregate/exception handles while excluding null, i31, functions and external values.
	(func $gc-address
		(param $value i64)
		(result i32)
		(local $tag i64)
		(local $offset i32)
		(local.set $tag (i64.and (local.get $value) (i64.const M4_GC_TAG_MASK)))
		;; Only these two exact tag patterns identify managed objects.
		(if (i32.or (i64.eq (local.get $tag) (i64.const M4_GC_OBJECT_TAG))
			(i64.eq (local.get $tag) (i64.const M4_GC_EXCEPTION_TAG)))
			(then
				(local.set $offset (i32.and (i32.wrap_i64 (local.get $value)) (i32.const M4_GC_ADDRESS_MASK)))
				;; Trusted reference slots must still lie within this instance's initialized object arena.
				(if (i32.lt_u (local.get $offset) (global.get $gc-object-used))
					(then (return (i32.add (global.get $gc-object-base) (local.get $offset))))
				)
			)
		)
		(i32.const 0)
	)

	;; Mark one previously unvisited object and append it to a bounded iterative tracing queue.
	(func $gc-mark
		(param $value i64)
		(local $object i32)
		(local $flags i32)
		(local.set $object (call $gc-address (local.get $value)))
		;; Non-managed references need no tracing; typed roots cannot manufacture interior pointers.
		(if (local.get $object)
			(then
				(local.set $flags (i32.load offset=M4_GC_FLAGS_OFFSET (local.get $object)))
				;; Already visited and free blocks cannot enter the queue twice.
				(if (i32.eqz (i32.and (local.get $flags) (i32.const m4_eval(M4_GC_FREE|M4_GC_MARK))))
					(then
						(i32.store offset=M4_GC_FLAGS_OFFSET
							(local.get $object)
							(i32.or (local.get $flags) (i32.const M4_GC_MARK))
						)
						(i32.store
							(i32.add
								(global.get $gc-queue-base)
								(i32.shl (global.get $gc-queue-count) (i32.const 2))
							)
							(local.get $object)
						)
						(global.set $gc-queue-count (i32.add (global.get $gc-queue-count) (i32.const 1)))
					)
				)
			)
		)
	)

	;; Set or clear the host-root bit for a JavaScript-owned opaque reference without altering its identity.
	(func (export "gc_pin")
		(param $value i64)
		(param $live i32)
		(local $object i32)
		(local $flags i32)
		(local.set $object (call $gc-address (local.get $value)))
		;; Host wrappers pin only managed handles; ordinary external and i31 values have no allocation.
		(if (local.get $object)
			(then
				(local.set $flags
					(i32.and (i32.load offset=M4_GC_FLAGS_OFFSET (local.get $object)) (i32.const m4_eval(~M4_GC_HOST_ROOT)))
				)
				(i32.store offset=M4_GC_FLAGS_OFFSET (local.get $object)
					(i32.or (local.get $flags) (select (i32.const M4_GC_HOST_ROOT) (i32.const 0) (local.get $live))))
			)
		)
	)

	;; Record one reference-bearing exception payload position in its hidden variable-width type bitmap.
	(func $gc-exception-mask
		(param $object i32)
		(param $index i32)
		(local $mask i32)
		(local.set $mask (i32.add (call $gc-slot (local.get $object) (i32.load offset=4 (local.get $object)))
			(i32.shl (i32.shr_u (local.get $index) (i32.const 6)) (i32.const 3))))
		(i64.store (local.get $mask) (i64.or (i64.load (local.get $mask))
			(i64.shl (i64.const 1) (i64.extend_i32_u (local.get $index)))))
	)

	;; Trace a frame's saved reference operands, excluding consumed arguments now owned by its callee.
	(func $gc-frame-stack
		(param $pc i32)
		(param $base i32)
		(param $end i32)
		(local $map i32)
		(local $i i32)
		(local $count i32)
		(local $slot i32)
		(local.set $map (i32.load (i32.add (global.get $gc-map-index-base) (i32.shl (local.get $pc) (i32.const 2)))))
		;; Numeric-only sites have no root map.
		(if (local.get $map)
			(then
				(local.set $count (i32.load16_u (local.get $map)))
				(block $done
					;; Saved indices are relative to this function's operand base, not the global stack origin.
					(loop $roots
						(br_if $done (i32.eq (local.get $i) (local.get $count)))
						(local.set $slot (i32.add (local.get $base) (i32.load16_u offset=2
							(i32.add (local.get $map) (i32.shl (local.get $i) (i32.const 1))))))
						;; Suspended callers retain only operands below their child's base.
						(if (i32.lt_u (local.get $slot) (local.get $end))
							(then
								(call $gc-mark
									(i64.load
										(i32.add
											(global.get $stack-base)
											(i32.shl (local.get $slot) (i32.const 3))
										)
									)
								)
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $roots)
					)
				)
			)
		)
	)

	;; Mark module resources, constructor temporaries and all live guest frames using their declared types.
	(func $gc-roots
		(local $i i32)
		(local $j i32)
		(local $record i32)
		(local $frame i32)
		(local $function i32)
		(local $count i32)
		(local $pc i32)
		(local $end i32)
		(block $globals-done
			;; Canonical aliases can be visited repeatedly without duplicating queue entries.
			(loop $globals
				(br_if $globals-done (i32.eq (local.get $i) (global.get $global-count)))
				(local.set $record (call $canonical-global-record (local.get $i)))
				;; Initializer snapshots remain roots only until resource instantiation completes.
				(if (i32.and (i32.ne (local.get $i) (global.get $gc-replacing-global))
					(call $is-reference (i32.load offset=12 (local.get $record))))
					(then
						(call $gc-mark (i64.load offset=24 (local.get $record)))
						;; Deferred initialization can still refer to the original constant value.
						(if
							(global.get $gc-initializing)
							(then (call $gc-mark (i64.load offset=16 (local.get $record))))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $globals)
			)
		)
		(local.set $i (i32.const 0))
		(block $tables-done
			;; Tables pack every nullable reference as its raw handle minus one.
			(loop $tables
				(br_if $tables-done (i32.eqz (global.get $gc-tables-ready)))
				(br_if $tables-done (i32.eq (local.get $i) (global.get $guest-table-present)))
				(local.set $record (call $canonical-table-record (local.get $i)))
				(local.set $j (i32.const 0))
				(block $entries-done
					;; Every declared table entry is a reference; no numeric data is scanned.
					(loop $entries
						(br_if $entries-done (i32.eq (local.get $j) (i32.load offset=8 (local.get $record))))
						(call $gc-mark (i64.extend_i32_u (i32.add (i32.load offset=64
							(i32.add (local.get $record) (i32.shl (local.get $j) (i32.const 2)))) (i32.const 1))))
						(local.set $j (i32.add (local.get $j) (i32.const 1)))
						(br $entries)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $tables)
			)
		)
		(local.set $i (i32.const 0))
		(block $segments-done
			;; Live passive entries and partially parsed initialization lists preserve allocated constants.
			(loop $segments
				(br_if $segments-done (i32.eq (local.get $i) (global.get $element-count)))
				(local.set $record (call $element-record (local.get $i)))
				(local.set $count
					(select
						(i32.load offset=8 (local.get $record))
						(i32.load offset=44 (local.get $record))
						(global.get $gc-initializing)
					)
				)
				(local.set $j (i32.const 0))
				(block $elements-done
					;; Deferred expressions carry source offsets and are not object handles until evaluated.
					(loop $elements
						(br_if $elements-done (i32.eq (local.get $j) (local.get $count)))
						(local.set $frame (i32.add (global.get $element-entry-base)
							(i32.shl (i32.add (i32.load offset=4 (local.get $record)) (local.get $j)) (i32.const 4))))
						;; Only directly stored constants retain objects; global expressions are already rooted above.
						(if (i32.and (i32.eq (i32.load offset=12 (local.get $frame)) (i32.const M4_OP_REF_I31))
							(i32.ge_s (i32.load offset=8 (local.get $frame)) (i32.const 0)))
							(then
								(call $gc-mark
									(i64.extend_i32_u (i32.add (i32.load (local.get $frame)) (i32.const 1)))
								)
							)
						)
						(local.set $j (i32.add (local.get $j) (i32.const 1)))
						(br $elements)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $segments)
			)
		)
		(local.set $i (i32.const 0))
		(block $temps-done
			;; Nested constant constructors store only reference values in this explicit native root stack.
			(loop $temps
				(br_if $temps-done (i32.eq (local.get $i) (global.get $gc-temp-count)))
				(call $gc-mark (i64.load (i32.add (global.get $gc-temp-base) (i32.shl (local.get $i) (i32.const 3)))))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $temps)
			)
		)
		(local.set $i (i32.const 0))
		(block $frames-done
			;; Explicit guest frames bound traversal independently from the native Wasm stack.
			(loop $frames
				(br_if $frames-done (i32.eq (local.get $i) (global.get $gc-calls)))
				(local.set $frame (i32.add (global.get $call-base) (i32.mul (local.get $i) (global.get $call-bytes))))
				(local.set $function (i32.load offset=M4_CALL_FUNCTION_OFFSET (local.get $frame)))
				;; Synthetic boundaries retain their saved exception without pretending to be guest functions.
				(if (i32.eq (local.get $function) (i32.const -1))
					(then (call $gc-mark (i64.load offset=M4_REENTRY_EXCEPTION_VALUE_OFFSET (local.get $frame))))
					;; Ordinary guest frames use their precise declared local and operand maps.
					(else
						(local.set $j (i32.const 0))
						(block $locals-done
							;; Stale inactive frames and undeclared local slots are never scanned.
							(loop $locals
								(br_if $locals-done
									(i32.eq
										(local.get $j)
										(i32.load offset=M4_FUNCTION_LOCALS_OFFSET
											(call $function (local.get $function))
										)
									)
								)
								;; Declared reference locals remain roots even when their bits resemble scalar values.
								(if (call $is-reference (i32.load (call $local-type (local.get $function) (local.get $j))))
									(then (call $gc-mark (i64.load offset=M4_CALL_LOCALS_OFFSET
										(i32.add (local.get $frame) (i32.shl (local.get $j) (i32.const 3))))))
								)
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $locals)
							)
						)
						(local.set $pc (global.get $gc-pc))
						(local.set $end (global.get $gc-stack-end))
						;; Suspended caller PCs point just after the call whose pre-stack map we saved.
						(if (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (global.get $gc-calls))
							(then
								(local.set $pc (i32.sub (i32.load (local.get $frame)) (i32.const 1)))
								(local.set $end
									(i32.load offset=M4_CALL_STACK_BASE_OFFSET
										(i32.add (local.get $frame) (global.get $call-bytes))
									)
								)
							)
						)
						(call $gc-frame-stack
							(local.get $pc)
							(i32.load offset=M4_CALL_STACK_BASE_OFFSET (local.get $frame))
							(local.get $end)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $frames)
			)
		)
		;; Pending propagation needs its exception independently from guest operands.
		(if (global.get $exception-pending) (then (call $gc-mark (global.get $exception-value))))
	)

	;; Trace reference fields and exception payloads iteratively, including cycles and shared subgraphs.
	(func $gc-trace
		(local $cursor i32)
		(local $object i32)
		(local $heap i32)
		(local $record i32)
		(local $i i32)
		(local $count i32)
		(local $field i32)
		(local $type i32)
		(local $mask i32)
		(block $done
			;; Each marked allocation enters the queue exactly once, bounded by arena/header size.
			(loop $objects
				(br_if $done (i32.eq (local.get $cursor) (global.get $gc-queue-count)))
				(local.set $object
					(i32.load
						(i32.add (global.get $gc-queue-base) (i32.shl (local.get $cursor) (i32.const 2)))
					)
				)
				(local.set $heap (i32.load (local.get $object)))
				;; Numeric arrays contain no outgoing references, so tracing their elements is unnecessary.
				(if (i32.ge_s (local.get $heap) (i32.const 0))
					(then
						(local.set $record (call $heap-record (local.get $heap)))
						;; Structs still inspect each declared field; reference arrays inspect every element.
						(if (i32.and (i32.eq (i32.load (local.get $record)) (i32.const 2))
							(i32.eqz (call $is-reference (i32.load (call $field-record (i32.load offset=20 (local.get $record)))))))
							(then (local.set $cursor (i32.add (local.get $cursor) (i32.const 1))) (br $objects))
						)
					)
				)
				(local.set $count (i32.load offset=4 (local.get $object)))
				(local.set $i (i32.const 0))
				;; Exception masks describe payload reference kinds even when the receiving module has no tag alias.
				(if (i32.lt_s (local.get $heap) (i32.const 0))
					(then
						(local.set $mask (call $gc-slot (local.get $object) (local.get $count)))
						(block $payload-done
							;; Skip the identity slot and inspect only mask-selected payload slots.
							(loop $payload
								(br_if $payload-done (i32.eq (local.get $i) (i32.sub (local.get $count) (i32.const 1))))
								;; The bitmap has one exact bit for each configured payload position.
								(if (i64.ne (i64.and (i64.load (i32.add (local.get $mask)
									(i32.shl (i32.shr_u (local.get $i) (i32.const 6)) (i32.const 3))))
									(i64.shl (i64.const 1) (i64.extend_i32_u (local.get $i)))) (i64.const 0))
									(then
										(call $gc-mark
											(i64.load
												(call $gc-slot
													(local.get $object)
													(i32.add (local.get $i) (i32.const 1))
												)
											)
										)
									)
								)
								(local.set $i (i32.add (local.get $i) (i32.const 1)))
								(br $payload)
							)
						)
					)
					;; Struct fields use distinct declared types; arrays repeat one element type.
					(else
						(local.set $record (call $heap-record (local.get $heap)))
						(block $fields-done
							;; Traverse the object's actual dynamic field/element count.
							(loop $fields
								(br_if $fields-done (i32.eq (local.get $i) (local.get $count)))
								(local.set $field (i32.load offset=20 (local.get $record)))
								;; Arrays retain their first field descriptor for every element.
								(if (i32.eq (i32.load (local.get $record)) (i32.const 1))
									(then (local.set $field (i32.add (local.get $field) (local.get $i))))
								)
								(local.set $type (i32.load (call $field-record (local.get $field))))
								;; Packed, numeric and vector fields cannot retain objects accidentally.
								(if (call $is-reference (local.get $type))
									(then (call $gc-mark (i64.load (call $gc-slot (local.get $object) (local.get $i)))))
								)
								(local.set $i (i32.add (local.get $i) (i32.const 1)))
								(br $fields)
							)
						)
					)
				)
				(local.set $cursor (i32.add (local.get $cursor) (i32.const 1)))
				(br $objects)
			)
		)
	)

	;; Mark every host-owned allocation, trace roots, coalesce unreachable blocks and release the free tail.
	(func $gc-collect
		(local $object i32)
		(local $end i32)
		(local $flags i32)
		(local $size i32)
		(local $free i32)
		(local $previous i32)
		(global.set $gc-queue-count (i32.const 0))
		(local.set $end (i32.add (global.get $gc-object-base) (global.get $gc-object-used)))
		(local.set $object (global.get $gc-object-base))
		(block $hosts-done
			;; Header walks follow stored allocation sizes, never stale payload bytes.
			(loop $hosts
				(br_if $hosts-done (i32.eq (local.get $object) (local.get $end)))
				(local.set $flags (i32.load offset=M4_GC_FLAGS_OFFSET (local.get $object)))
				;; A host-held opaque value is a root even if the guest no longer stores it.
				(if (i32.and (local.get $flags) (i32.const M4_GC_HOST_ROOT))
					(then (call $gc-mark (call $gc-reference (local.get $object))))
				)
				(local.set $object
					(i32.add (local.get $object) (i32.and (local.get $flags) (i32.const M4_GC_SIZE_MASK)))
				)
				(br $hosts)
			)
		)
		(call $gc-roots)
		(call $gc-trace)
		(global.set $gc-free (i32.const 0))
		(global.set $gc-live (i32.const 0))
		(local.set $object (global.get $gc-object-base))
		(block $sweep-done
			;; Consecutive dead blocks become one first-fit free span, preserving every live address.
			(loop $sweep
				(br_if $sweep-done (i32.eq (local.get $object) (local.get $end)))
				(local.set $flags (i32.load offset=M4_GC_FLAGS_OFFSET (local.get $object)))
				(local.set $size (i32.and (local.get $flags) (i32.const M4_GC_SIZE_MASK)))
				;; Marked blocks survive and lose only their transient mark bit.
				(if (i32.and (local.get $flags) (i32.const M4_GC_MARK))
					(then
						(i32.store offset=M4_GC_FLAGS_OFFSET
							(local.get $object)
							(i32.and (local.get $flags) (i32.const m4_eval(~M4_GC_MARK)))
						)
						(global.set $gc-live (i32.add (global.get $gc-live) (local.get $size)))
						(local.set $free (i32.const 0))
					)
					;; Unmarked blocks are coalesced into the current free span or linked as a new span.
					(else
						;; A nonzero free cursor means the preceding block was also unreachable.
						(if (local.get $free)
							(then (i32.store offset=M4_GC_FLAGS_OFFSET (local.get $free)
								(i32.add (i32.load offset=M4_GC_FLAGS_OFFSET (local.get $free)) (local.get $size))))
							;; Begin a new span and link it after the previous free span, if any.
							(else
								(local.set $free (local.get $object))
								(i32.store (local.get $free) (i32.const 0))
								(i32.store offset=M4_GC_FLAGS_OFFSET
									(local.get $free)
									(i32.or (local.get $size) (i32.const M4_GC_FREE))
								)
								;; The first span becomes the list head.
								(if (local.get $previous)
									(then (i32.store (local.get $previous) (local.get $free)))
									(else (global.set $gc-free (local.get $free)))
								)
								(local.set $previous (local.get $free))
							)
						)
					)
				)
				(local.set $object (i32.add (local.get $object) (local.get $size)))
				(br $sweep)
			)
		)
		;; A dead trailing span is returned to the bump allocator instead of occupying the free list.
		(if (local.get $free)
			(then
				(global.set $gc-object-used (i32.sub (local.get $free) (global.get $gc-object-base)))
				;; Locate the preceding free-list link without touching any surviving object.
				(if (i32.eq (global.get $gc-free) (local.get $free))
					(then (global.set $gc-free (i32.const 0)))
					(else
						(local.set $object (global.get $gc-free))
						;; The tail exists in the list, so this search terminates at its predecessor.
						(loop $unlink
							;; Remove the final link as soon as its predecessor is found.
							(if (i32.eq (i32.load (local.get $object)) (local.get $free))
								(then (i32.store (local.get $object) (i32.const 0)))
								;; Earlier links lead to the predecessor without revisiting any block.
								(else (local.set $object (i32.load (local.get $object))) (br $unlink))
							)
						)
					)
				)
			)
		)
	)

	;; Collect idle instances without retaining completed invocation frames or obsolete result slots.
	(func (export "collect_garbage")
		(global.set $error (i32.const M4_ERR_SUCCESS))
		;; Low-level callers must not discard roots while a guest import is suspended.
		(if (i32.ge_s (global.get $pending-import) (i32.const 0))
			(then (call $fail (i32.const M4_ERR_SUSPENDED_REENTRY)) (return))
		)
		(global.set $gc-calls (i32.const 0))
		(call $gc-collect)
	)

	;; Report allocated live bytes, including private object headers, for explicit collection accounting.
	(func (export "gc_live_bytes")
		(result i32) (global.get $gc-live))
	;; Exclude the obsolete value of a deferred initializer while its replacement graph is constructed.
	(func $gc-replace-initializer
		(param $index i32)
		(param $reference i32)
		(param $type i32)
		(result i64)
		(local $previous i32)
		(local $value i64)
		(local.set $previous (global.get $gc-replacing-global))
		(global.set $gc-replacing-global (local.get $index))
		(local.set $value (call $initializer-value (local.get $reference) (local.get $type)))
		(global.set $gc-replacing-global (local.get $previous))
		(local.get $value)
	)
