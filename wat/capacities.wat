	;; Configure quotas on a fresh instance before any load has established record or memory addresses.
	(func (export "configure_limits")
		(param $functions i32)
		(param $exports i32)
		(param $globals i32)
		(param $calls i32)
		(param $pages i32)
		(result i32)

		;; Loaded instances cannot change capacities underneath active resource bindings.
		(if (global.get $code-base)
			(then (return (i32.const M4_ERR_INVALID_RESUME)))
		)
		;; Keep namespace quotas and address-width bounds independent from allocated storage.
		(if
			(i32.or
				(i32.or (i32.gt_u (local.get $functions) (i32.const M4_LIMIT_FUNCTIONS))
					(i32.gt_u (local.get $exports) (i32.const M4_LIMIT_FUNCTIONS)))
				(i32.or (i32.gt_u (local.get $globals) (i32.const M4_LIMIT_FUNCTIONS))
					(i32.or (i32.or (i32.eqz (local.get $calls))
						(i32.gt_u (local.get $calls) (i32.const M4_CAP_CONTROLS)))
						(i32.gt_u (local.get $pages) (i32.const 65536))))
			)
			(then (return (i32.const M4_ERR_INVALID_BUFFER)))
		)
		(global.set $function-limit (local.get $functions))
		(global.set $export-limit (local.get $exports))
		(global.set $global-limit (local.get $globals))
		(global.set $call-limit (local.get $calls))
		(global.set $guest-capacity (local.get $pages))
		(i32.const 0)
	)

	;; Append an aligned metadata arena during prepare, preserving all fixed interpreter regions.
	(func $reserve-owned
		(param $bytes i64)
		(result i32)
		(local $base i32)
		(local $end i64)

		;; An earlier failed reservation leaves all later optional arenas unchanged.
		(if (global.get $error) (then (return (i32.const 0))))
		(local.set $base (global.get $owned-end))
		(local.set $end (i64.add (i64.extend_i32_u (local.get $base)) (local.get $bytes)))
		;; Memory growth must succeed before any pointer or logical size changes.
		(if (i32.eqz (call $ensure-bytes (i64.add (local.get $end) (i64.const 1024))))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		(global.set $owned-end (i32.wrap_i64 (local.get $end)))
		(global.set $host-base (global.get $owned-end))
		(local.get $base)
	)

	;; Reserve optional larger export, global and call arenas before any parser or guest retains their pointers.
	(func $prepare-capacities
		(result i32)

		;; Small/default export quotas retain the original fast layout.
		(if (i32.gt_u (global.get $export-limit) (i32.const M4_LIMIT_EXPORTS))
			(then
				(global.set $export-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $export-limit)) (i64.const 32))))
			)
		)
		;; Extra globals have the same descriptor layout and alias rules as the original arena.
		(if (i32.gt_u (global.get $global-limit) (i32.const M4_LIMIT_GLOBALS))
			(then
				(global.set $global-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $global-limit)) (i64.const 80))))
			)
		)
		;; Additional frames require both the low-slot records and parallel vector high halves.
		(if (i32.gt_u (global.get $call-limit) (i32.const M4_CAP_CALLS))
			(then
				(global.set $call-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $call-limit)) (i64.const M4_CALL_BYTES))))
				(global.set $call-high-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $call-limit)) (i64.const M4_LOCAL_NAME_BYTES))))
			)
		)
		(i32.eqz (global.get $error))
	)

	;; Extend owned metadata and move initialized linear memories together without changing guest addresses.
	(func $extend-owned
		(param $end i64)
		(result i32)
		(local $linear i64)
		(local $required i64)
		(local $delta i32)
		(local $i i32)
		(local $record i32)

		(local.set $required (i64.add (local.get $end) (i64.const 1024)))
		;; Initialized memories begin at a page boundary and remain packed after the growing metadata.
		(if (global.get $resources-allocated)
			(then
				(local.set $linear (i64.and (i64.add (local.get $end) (i64.const 65535)) (i64.const -65536)))
				(local.set $required (i64.add (local.get $linear)
					(i64.add (i64.extend_i32_u (i32.sub (global.get $host-base) (global.get $linear-base))) (i64.const 1024))))
			)
		)
		;; Reject wrapping layouts and failed physical growth before moving any live bytes.
		(if (i32.eqz (call $ensure-bytes (local.get $required)))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		;; Post-load foreign function records can trigger growth while memory bindings already exist.
		(if (global.get $resources-allocated)
			(then
				(local.set $delta (i32.sub (i32.wrap_i64 (local.get $linear)) (global.get $linear-base)))
				(memory.copy (i32.wrap_i64 (local.get $linear)) (global.get $linear-base)
					(i32.add (i32.sub (global.get $host-base) (global.get $linear-base)) (i32.const 1024)))
				(block $done
					;; Aliases retain their canonical descriptor rather than acquiring duplicate physical storage.
					(loop $memories
						(br_if $done (i32.eq (local.get $i) (global.get $memory-present)))
						(local.set $record (call $memory-record (local.get $i)))
						;; Every canonical region moves by the same amount, including zero-page memories.
						(if (i32.eqz (i32.load offset=52 (local.get $record)))
							(then (i32.store offset=20 (local.get $record)
								(i32.add (i32.load offset=20 (local.get $record)) (local.get $delta))))
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $memories)
					)
				)
				(global.set $host-base (i32.add (global.get $host-base) (local.get $delta)))
				(global.set $linear-base (i32.wrap_i64 (local.get $linear)))
				(call $use-memory (global.get $memory-index))
			)
			;; During parsing, no linear memory or active guest arguments exist beyond the owned layout.
			(else (global.set $host-base (i32.wrap_i64 (local.get $end))))
		)
		(global.set $owned-end (i32.wrap_i64 (local.get $end)))
		(i32.const 1)
	)

	;; Grow the function namespace and all associated tables geometrically, preserving numeric function identities.
	(func $reserve-function
		(result i32)
		(local $capacity i32)
		(local $functions i32)
		(local $names i32)
		(local $types i32)
		(local $metadata i32)
		(local $declarations i32)
		(local $index i32)
		(local $end i64)

		;; Instance quota failures occur before storage allocation or any declaration writes.
		(if (i32.ge_u (global.get $function-count) (global.get $function-limit))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		;; Existing capacity, including the original 512 slots, needs no allocation or relocation.
		(if (i32.lt_u (global.get $function-count) (global.get $function-capacity))
			(then (return (i32.const 1)))
		)
		(local.set $capacity (i32.shl (global.get $function-capacity) (i32.const 1)))
		(local.set $end (i64.add (i64.extend_i32_u (global.get $function-arena))
			(i64.add
				(i64.mul (i64.extend_i32_u (local.get $capacity))
					(i64.const m4_eval(M4_FUNCTION_RECORD_BYTES+M4_LOCAL_NAME_BYTES+M4_FUNCTION_LOCAL_TYPES_BYTES+M4_FUNCTION_TYPES_BYTES+32)))
				(i64.extend_i32_u (i32.shr_u (local.get $capacity) (i32.const 3))))))
		;; Physical growth and any linear-memory relocation must complete before source tables are overwritten.
		(if (i32.eqz (call $extend-owned (local.get $end))) (then (return (i32.const 0))))
		(local.set $functions (global.get $function-arena))
		(local.set $names
			(i32.add
				(local.get $functions)
				(i32.mul (local.get $capacity) (i32.const M4_FUNCTION_RECORD_BYTES))
			)
		)
		(local.set $types (i32.add (local.get $names) (i32.mul (local.get $capacity) (i32.const M4_LOCAL_NAME_BYTES))))
		(local.set $metadata
			(i32.add
				(local.get $types)
				(i32.mul (local.get $capacity) (i32.const M4_FUNCTION_LOCAL_TYPES_BYTES))
			)
		)
		(local.set $declarations
			(i32.add
				(local.get $metadata)
				(i32.mul (local.get $capacity) (i32.const M4_FUNCTION_TYPES_BYTES))
			)
		)
		(local.set $index (i32.add (local.get $declarations) (i32.shr_u (local.get $capacity) (i32.const 3))))
		;; Reverse layout order preserves overlapping old tables when an already dynamic arena grows in place.
		(memory.copy (local.get $declarations) (global.get $function-declarations)
			(i32.shr_u (global.get $function-capacity) (i32.const 3)))
		(memory.fill (i32.add (local.get $declarations) (i32.shr_u (global.get $function-capacity) (i32.const 3)))
			(i32.const 0) (i32.shr_u (global.get $function-capacity) (i32.const 3)))
		(memory.copy (local.get $metadata) (global.get $function-type-base)
			(i32.mul (global.get $function-count) (i32.const M4_FUNCTION_TYPES_BYTES)))
		(memory.copy (local.get $types) (global.get $local-type-base)
			(i32.mul (global.get $function-count) (i32.const M4_FUNCTION_LOCAL_TYPES_BYTES)))
		(memory.copy (local.get $names) (global.get $local-name-base)
			(i32.mul (global.get $function-count) (i32.const M4_LOCAL_NAME_BYTES)))
		(memory.copy (local.get $functions) (global.get $function-base)
			(i32.mul (global.get $function-count) (i32.const M4_FUNCTION_RECORD_BYTES)))
		(global.set $function-base (local.get $functions))
		(global.set $local-name-base (local.get $names))
		(global.set $local-type-base (local.get $types))
		(global.set $function-type-base (local.get $metadata))
		(global.set $function-declarations (local.get $declarations))
		(global.set $function-name-index (local.get $index))
		(global.set $function-name-mask (i32.sub (i32.shl (local.get $capacity) (i32.const 1)) (i32.const 1)))
		(global.set $function-names-indexed (i32.const 0))
		(global.set $function-capacity (local.get $capacity))
		(i32.const 1)
	)
