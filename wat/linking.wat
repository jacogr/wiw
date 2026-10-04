	;; Expose validated export descriptors so the host can register every resource kind.
	(func (export "exports_count")
		(result i32)

		(global.get $export-count)
	)

	;; Return an export descriptor address only within the loaded module's descriptor prefix.
	(func (export "export_info")
		(param $index i32)
		(result i32)

		;; Invalid queries cannot expose adjacent arenas.
		(if (result i32) (i32.lt_u (local.get $index) (global.get $export-count))
			(then
				(i32.add (global.get $export-base) (i32.mul (local.get $index) (i32.const 32)))
			)
			;; Out-of-range descriptors have no address.
			(else
				(i32.const 0)
			)
		)
	)

	;; Return a global's protected descriptor for validated linking and raw-value synchronization.
	(func (export "global_info")
		(param $index i32)
		(result i32)

		;; Global descriptor access is bounded by the parsed index space.
		(if (result i32) (i32.lt_u (local.get $index) (global.get $global-count))
			(then
				(call $global-record (local.get $index))
			)
			;; Missing globals never expose an unrelated record.
			(else
				(i32.const 0)
			)
		)
	)

	;; Report the declared memory minimum used for import compatibility checks.
	(func (export "memory_min")
		(result i32)

		(global.get $guest-min)
	)

	;; Report an explicit memory maximum, or -1 when the declaration leaves it unbounded.
	(func (export "memory_max")
		(result i32)

		(select (global.get $guest-max) (i32.const -1) (global.get $memory-max-present))
	)

	;; Return one table's current number of entries to the trusted host adapter.
	(func (export "table_size")
		(param $index i32)
		(result i32)

		(i32.load offset=8 (call $canonical-table-record (local.get $index)))
	)

	;; Return one table's declared maximum or -1 for an unbounded declaration.
	(func (export "table_max")
		(param $index i32)
		(result i32)

		(i32.load offset=12 (call $canonical-table-record (local.get $index)))
	)

	;; Expose the reference type of an independently indexed table.
	(func (export "table_type")
		(param $index i32)
		(result i32)

		(i32.load offset=16 (call $canonical-table-record (local.get $index)))
	)

	;; Expose one table's protected entry arena to the synchronous binding adapter.
	(func (export "table_base")
		(param $index i32)
		(result i32)

		(i32.add (call $canonical-table-record (local.get $index)) (i32.const 64))
	)

	;; Install compatible imported limits before allocating initial entries.
	(func (export "bind_guest_table")
		(param $index i32)
		(param $size i32)
		(param $maximum i32)
		(result i32)

		;; Reject oversized actual imports before modifying their descriptor.
		(if (i32.gt_u (local.get $size) (i32.const 4096))
			(then
				(return (i32.const 6))
			)
		)
		(i32.store offset=8 (call $guest-table-record (local.get $index)) (local.get $size))
		(i32.store offset=12 (call $guest-table-record (local.get $index)) (local.get $maximum))
		(i32.const 0)
	)

	;; Give repeated imports of one shared table a single local entry arena.
	(func (export "alias_guest_table")
		(param $index i32)
		(param $canonical i32)

		(i32.store offset=20
			(call $guest-table-record (local.get $index))
			(i32.add (local.get $canonical) (i32.const 1))
		)
	)

	;; Synchronize growth of one shared table, initializing new entries to null.
	(func (export "grow_guest_table")
		(param $index i32)
		(param $delta i32)
		(result i32)

		(call $use-table (local.get $index))
		(call $table-grow (i64.const 0) (local.get $delta))
	)

	;; Allocate resources using validated actual import sizes before the host installs their contents.
	(func (export "prepare_resource_imports")
		(param $pages i32)
		(param $maximum i32)
		(param $entries i32)
		(param $table-maximum i32)
		(result i32)

		;; Standalone modules have already allocated and initialized their own resources.
		(if (i32.eqz (global.get $resource-phase))
			(then
				(return (i32.const 0))
			)
		)
		;; Reject sizes beyond the engine's fixed arenas before changing any bound sizes.
		(if
			(i32.or
				(i32.gt_u (local.get $pages) (i32.const CAP_PAGES))
				(i32.gt_u (local.get $entries) (i32.const 4096))
			)
			(then
				(call $fail (i32.const 6))
				(return (global.get $error))
			)
		)
		(global.set $guest-min (local.get $pages))
		(global.set $guest-max
			(select
				(i32.const 65536)
				(local.get $maximum)
				(i32.eq (local.get $maximum) (i32.const -1))
			)
		)
		(global.set $memory-max-present (i32.ne (local.get $maximum) (i32.const -1)))
		(call $allocate-table)
		(call $allocate-resources)
		(global.set $resource-phase (i32.const 2))
		(global.get $error)
	)

	;; Allocate a typed suspended-call function representing a foreign shared-table entry.
	(func (export "foreign_function")
		(param $count i32)
		(param $result i32)
		(param $types i32)
		(param $slot i32)
		(result i32)
		(local $index i32)
		(local $f i32)
		(local $i i32)

		(global.set $error (i32.const 0))
		;; Host-created function records obey the same fixed function and parameter capacities.
		(if
			(i32.or
				(i32.ge_u (global.get $function-count) (i32.const CAP_FUNCTIONS))
				(i32.gt_u (local.get $count) (i32.const 128))
			)
			(then
				(call $fail (i32.const 6))
				(return (i32.const -1))
			)
		)
		(local.set $index (global.get $function-count))
		(local.set $f (call $function (local.get $index)))
		(i32.store offset=8 (local.get $f) (i32.const -1))
		(i32.store offset=12 (local.get $f) (local.get $slot))
		(i32.store offset=16 (local.get $f) (local.get $count))
		(i32.store offset=20 (local.get $f) (local.get $count))
		(i32.store offset=24 (local.get $f) (local.get $result))
		;; Copy the complete parameter vector used by structural indirect-call checking.
		(block $done
			;; Mixed scalar signatures retain their declaration order.
			(loop $params
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(i32.store8
					(call $local-type (local.get $index) (local.get $i))
					(i32.load8_u (i32.add (local.get $types) (local.get $i)))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $params)
			)
		)
		(global.set $function-count (i32.add (local.get $index) (i32.const 1)))
		(local.get $index)
	)

	;; Invoke a validated internal function index so shared tables can retain unexported functions.
	(func (export "invoke_index64")
		(param $index i32)
		(param $args i32)
		(param $count i32)
		(result i64)
		(local $i i32)
		(local $f i32)

		(global.set $error (i32.const 0))
		;; Suspended invocations and unfinished starts retain exclusive use of execution state.
		(if
			(i32.or
				(i32.ge_s (global.get $pending-import) (i32.const 0))
				(i32.and
					(i32.ne (global.get $start-state) (i32.const 3))
					(i32.ne (global.get $start-state) (i32.const 0))
				)
			)
			(then
				(call $fail (i32.const 22))
				(return (i64.const 0))
			)
		)
		;; Failed loads and invalid internal indices cannot enter guest code.
		(if
			(i32.or
				(i32.eqz (i32.or (global.get $ready) (global.get $segments-ready)))
				(i32.ge_u (local.get $index) (global.get $function-count))
			)
			(then
				(call $fail (i32.const 10))
				(return (i64.const 0))
			)
		)
		(local.set $f (call $function (local.get $index)))
		;; Check host arity before reading any argument slot.
		(if (i32.ne (local.get $count) (i32.load offset=16 (local.get $f)))
			(then
				(call $fail (i32.const 11))
				(return (i64.const 0))
			)
		)
		;; Nonempty slot vectors must fit in native memory.
		(if
			(i32.and
				(local.get $count)
				(i32.eqz (call $buffer-ok (local.get $args) (i32.mul (local.get $count) (i32.const 8))))
			)
			(then
				(call $fail (i32.const 5))
				(return (i64.const 0))
			)
		)
		;; Copy arguments into protected slots before execution can grow backing memory.
		(block $done
			;; Canonicalize narrow values while retaining wide scalar bit patterns.
			(loop $args
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(i64.store
					(i32.add (global.get $argument-base) (i32.mul (local.get $i) (i32.const 8)))
					(call $canonical-value
						(i64.load (i32.add (local.get $args) (i32.mul (local.get $i) (i32.const 8))))
						(i32.load8_u (call $local-type (local.get $index) (local.get $i)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $args)
			)
		)
		(global.set $last-results (i32.load offset=24 (local.get $f)))
		(call $run (local.get $index) (global.get $argument-base))
	)

	;; Report successful segment initialization independently of a later start-function trap.
	(func (export "segments_ready")
		(result i32)

		(global.get $segments-ready)
	)

	;; Return a bounded function descriptor for shared-table binding resolution.
	(func (export "function_info")
		(param $index i32)
		(result i32)

		;; Only parsed or explicitly installed functions have descriptors.
		(if (result i32) (i32.lt_u (local.get $index) (global.get $function-count))
			(then
				(call $function (local.get $index))
			)
			;; Invalid indices expose no descriptor.
			(else
				(i32.const 0)
			)
		)
	)

	;; Install a foreign function's ordered result vector from trusted host type bytes.
	(func (export "foreign_results")
		(param $index i32)
		(param $types i32)
		(param $count i32)
		(result i32)
		(local $i i32)
		(local $shape i32)

		;; Function and vector limits apply before reading the caller's type bytes.
		(if
			(i32.or
				(i32.ge_u (local.get $index) (global.get $function-count))
				(i32.gt_u (local.get $count) (i32.const 64))
			)
			(then
				(return (i32.const 6))
			)
		)
		;; Finish after collecting all result types into the local shape arena.
		(block $done
			;; Foreign shape pointers never cross instance boundaries.
			(loop $types
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(local.set $shape
					(call $shape-append
						(local.get $shape)
						(i32.load8_u (i32.add (local.get $types) (local.get $i)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
		(i32.store offset=24 (call $function (local.get $index)) (local.get $shape))
		(global.get $error)
	)
