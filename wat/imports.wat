	;; Locate an import record: function index, module span, field span, then source offset.
	(func $import-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $import-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Read and decode module/field names into the next reserved import descriptor.
	(func $read-import-names
		(param $index i32)
		(local $record i32)
		(local $p i32)
		(local $n i32)

		;; Text imports precede all definitions, including definitions in other index spaces.
		(if (global.get $definitions-started)
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		;; Keep every import category within the shared descriptor arena.
		(if (i32.ge_u (global.get $import-count) (i32.const M4_CAP_IMPORTS))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return)
			)
		)
		(local.set $record (call $import-record (global.get $import-count)))
		;; Names overwrite the first six words; clear kind and reserved tail before this import is published.
		(i64.store offset=M4_IMPORT_KIND_OFFSET (local.get $record) (i64.const 0))
		(i32.store (local.get $record) (local.get $index))
		(i32.store offset=20 (local.get $record) (global.get $tok))
		(call $next)
		(local.set $p (global.get $tok))
		(local.set $n (global.get $len))
		(call $expect (i32.const 4))
		(i32.store offset=4 (local.get $record) (call $export-name (local.get $p) (local.get $n)))
		(i32.store offset=8 (local.get $record) (global.get $decoded-name-length))
		(local.set $p (global.get $tok))
		(local.set $n (global.get $len))
		(call $expect (i32.const 4))
		(i32.store offset=12
			(local.get $record)
			(call $export-name (local.get $p) (local.get $n))
		)
		(i32.store offset=16 (local.get $record) (global.get $decoded-name-length))
	)

	;; Parse a module-level MVP function import using the shared signature and name machinery.
	(func $parse-import
		(call $read-import-names (global.get $function-count))
		(call $expect (i32.const 1))
		(global.set $parsing-import (i32.const 1))
		;; Resource import descriptors share the name decoder but own distinct index spaces.
		(if (call $is-word (i32.const 80) (i32.const 6))
			(then
				(call $parse-memory)
				(call $expect (i32.const 2))
				(return)
			)
		)
		;; Global signatures contain their type and mutability, with their value supplied during linking.
		(if (call $is-word (i32.const 86) (i32.const 6))
			(then
				(call $parse-global)
				(call $expect (i32.const 2))
				(return)
			)
		)
		;; Imported tables declare the required limits and the MVP funcref element type.
		(if (call $is-word (i32.const 3840) (i32.const 5))
			(then
				(call $parse-table)
				(call $expect (i32.const 2))
				(return)
			)
		)
		;; Imported tags retain a host-provided exception identity and their complete type signature.
		(if (call $is-exception-word (i32.const 0))
			(then
				(call $parse-tag)
				(call $expect (i32.const 2))
				(return)
			)
		)
		;; Only a function keyword remains valid after the resource alternatives.
		(if (i32.eqz (call $is-word (i32.const 6) (i32.const 4)))
			(then
				(call $fail (i32.const M4_ERR_UNSUPPORTED))
				(return)
			)
		)
		(global.set $parsing-import (i32.const 1))
		(call $parse-function)
		(global.set $parsing-import (i32.const 0))
		(call $expect (i32.const 2))
		;; Publish a complete descriptor only after its signature and outer form are valid.
		(if (i32.eqz (global.get $error))
			(then
				(global.set $import-count (i32.add (global.get $import-count) (i32.const 1)))
			)
		)
	)

	;; Publish a resource import or mark a definition in its own MVP index space.
	(func $finish-resource-declaration
		(param $kind i32)
		(param $index i32)
		(local $record i32)
		(local $mask i32)

		(local.set $mask (i32.shl (i32.const 1) (local.get $kind)))
		;; Resource imports publish typed descriptors and defer resource initialization until linking.
		(if (global.get $parsing-import)
			(then
				;; Imports follow only earlier imports in the same index space.
				(if (i32.and (global.get $definitions-started) (local.get $mask))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return)
					)
				)
				;; Keep every import category within the shared descriptor arena.
				(if (i32.ge_u (global.get $import-count) (i32.const M4_CAP_IMPORTS))
					(then
						(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
						(return)
					)
				)
				(local.set $record (call $import-record (global.get $import-count)))
				(i32.store (local.get $record) (local.get $index))
				(i32.store offset=24 (local.get $record) (local.get $kind))
				(global.set $import-count (i32.add (global.get $import-count) (i32.const 1)))
				(global.set $resource-phase (i32.const 1))
				(global.set $parsing-import (i32.const 0))
			)
			;; Defined resources mark only their own space, leaving other import spaces available.
			(else
				(global.set $definitions-started
					(i32.or (global.get $definitions-started) (local.get $mask))
				)
			)
		)
	)

	;; Save explicit dispatch locals and identify the import whose arguments begin at the operand cursor.
	(func $suspend-import
		(param $index i32)
		(param $calls i32)
		(param $frame i32)
		(param $fuel i64)

		(global.set $pending-import (i32.load offset=12 (call $function (local.get $index))))
		(global.set $pending-offset (global.get $tok))
		(global.set $saved-calls (local.get $calls))
		(global.set $saved-frame (local.get $frame))
		(global.set $saved-fuel (local.get $fuel))
	)

	;; Suspend a directly exported imported function after copying its host arguments out of scratch.
	(func $root-import
		(param $index i32)
		(param $args i32)
		(result i64)
		(local $i i32)
		(local $count i32)

		(global.set $sp (i32.const 0))
		(global.set $control-count (i32.const 0))
		(global.set $tok (i32.load offset=28 (call $function (local.get $index))))
		;; A root import consumes one fuel unit just like an imported call instruction.
		(if (i64.eqz (global.get $fuel-limit))
			(then
				(call $fail (i32.const M4_ERR_EXHAUSTED_FUEL))
				(return (i64.const 0))
			)
		)
		(local.set $count (i32.load offset=16 (call $function (local.get $index))))
		;; Finish after copying every declared parameter into protected operand slots.
		(block $done
			;; Arguments must survive memory growth and scratch writes while the host handles the call.
			(loop $args
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				(i64.store
					(i32.add (global.get $stack-base) (i32.mul (local.get $i) (i32.const 8)))
					(i64.load (i32.add (local.get $args) (i32.mul (local.get $i) (i32.const 8))))
				)
				(i64.store
					(i32.add (global.get $stack-high-base) (i32.mul (local.get $i) (i32.const 8)))
					(i64.load
						(i32.add (global.get $argument-high-base) (i32.mul (local.get $i) (i32.const 8)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $args)
			)
		)
		(call $suspend-import
			(local.get $index)
			(i32.const 0)
			(i32.const 0)
			(i64.sub (global.get $fuel-limit) (i64.const 1))
		)
		(i64.const 0)
	)

	;; Return the number of declared function imports; the host resolves each before invocation.
	(func (export "import_count")
		(result i32)

		(global.get $import-count)
	)

	;; Return a valid import's descriptor address, or zero for an out-of-range index.
	(func (export "import_info")
		(param $index i32)
		(result i32)

		;; An invalid query must not expose another arena as an import record.
		(if (i32.ge_u (local.get $index) (global.get $import-count))
			(then
				(return (i32.const 0))
			)
		)
		(call $import-record (local.get $index))
	)

	;; Return a function's declared parameter count, or -1 for an invalid numeric index.
	(func (export "function_params")
		(param $index i32)
		(result i32)

		;; Type metadata is limited to actual functions in the loaded module.
		(if (i32.ge_u (local.get $index) (global.get $function-count))
			(then
				(return (i32.const -1))
			)
		)
		(i32.load offset=16 (call $function (local.get $index)))
	)

	;; Return a function's declared result count, or -1 for an invalid numeric index.
	(func (export "function_results")
		(param $index i32)
		(result i32)

		;; Reject invalid indices before dereferencing a function record.
		(if (i32.ge_u (local.get $index) (global.get $function-count))
			(then
				(return (i32.const -1))
			)
		)
		(call $shape-count (i32.load offset=24 (call $function (local.get $index))))
	)

	;; Resolve an exported function to its numeric index so a host can forward its declared signature.
	(func (export "export_function")
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 0)))
		;; Lookup failures return a sentinel; the host reads error_code for the cause.
		(if (global.get $error)
			(then
				(return (i32.const -1))
			)
		)
		(i32.load offset=8 (local.get $record))
	)

	;; Return the pending import slot, or -1 when execution has completed or failed.
	(func (export "pending_import")
		(result i32)

		(global.get $pending-import)
	)

	;; Return the protected native pointer to pending arguments; guest pointer values remain untranslated.
	(func (export "pending_args")
		(result i32)

		(i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8)))
	)

	;; Resume a suspended import with a wide-slot result or a host failure; preserve the original fuel budget.
	(func $resume64 (export "resume64")
		(param $value i64)
		(param $failed i32)
		(result i64)
		(local $index i32)
		(local $shape i32)
		(local $count i32)
		(local $high i64)

		(global.set $error (i32.const M4_ERR_SUCCESS))
		;; A result is only meaningful while an imported call is suspended.
		(if (i32.lt_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const M4_ERR_INVALID_RESUME))
				(return (call $finish-start (i64.const 0)))
			)
		)
		(local.set $index (i32.load (call $import-record (global.get $pending-import))))
		(global.set $pending-import (i32.const -1))
		(global.set $tok (global.get $pending-offset))
		;; Host exceptions and invalid results become an explicit guest call-site trap.
		(if (local.get $failed)
			(then
				(call $fail (i32.const M4_ERR_HOST_IMPORT))
				(return (call $finish-start (i64.const 0)))
			)
		)
		(local.set $shape (i32.load offset=24 (call $function (local.get $index))))
		(local.set $count (call $shape-count (local.get $shape)))
		;; Multivalue adapters place the complete vector at pending_args before resumption.
		(if (i32.gt_u (local.get $count) (i32.const 1))
			(then
				(local.set $value
					(i64.load (i32.add (global.get $stack-base) (i32.mul (global.get $sp) (i32.const 8))))
				)
			)
		)
		(local.set $value
			(call $canonical-value
				(local.get $value)
				(call $shape-type (local.get $shape) (i32.const 0))
			)
		)
		(local.set $high
			(i64.load
				(i32.add (global.get $stack-high-base) (i32.mul (global.get $sp) (i32.const 8)))
			)
		)
		;; Directly exported imports have no guest continuation and return immediately.
		(if (i32.eqz (global.get $saved-calls))
			(then
				(return
					(call $finish-start (select (local.get $value) (i64.const 0) (global.get $last-results)))
				)
			)
		)
		;; Void imports leave the operand cursor unchanged; singleton imports use the compatibility value.
		(if (i32.eq (local.get $count) (i32.const 1))
			(then
				(call $runtime-value (local.get $value))
				(i64.store
					(i32.add
						(global.get $stack-high-base)
						(i32.mul (i32.sub (global.get $sp) (i32.const 1)) (i32.const 8))
					)
					(local.get $high)
				)
			)
		)
		;; Multivalue results already occupy the protected slots above the saved cursor.
		(if (i32.gt_u (local.get $count) (i32.const 1))
			(then
				;; Check capacity before publishing the new cursor to dispatch.
				(if
					(i32.gt_u (i32.add (global.get $sp) (local.get $count)) (i32.const M4_CAP_OPERANDS))
					(then
						(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
					)
					;; The host validates every type and canonicalizes scalar result slots.
					(else
						(global.set $sp (i32.add (global.get $sp) (local.get $count)))
					)
				)
			)
		)
		;; A result allocation failure ends the invocation without restoring dispatch.
		(if (global.get $error)
			(then
				(return (call $finish-start (i64.const 0)))
			)
		)
		(global.set $resuming (i32.const 1))
		(call $finish-start (call $run (i32.const 0) (i32.const 0)))
	)

	;; Resume an i32-only compatibility invocation without truncating wide pending results.
	(func (export "resume")
		(param $value i32)
		(param $failed i32)
		(result i32)
		(local $type i32)

		;; A failed callback can abort either width; successful narrow resumes require i32 results.
		(if
			(i32.and
				(i32.eqz (local.get $failed))
				(i32.ge_s (global.get $pending-import) (i32.const 0))
			)
			(then
				(local.set $type
					(i32.load offset=24
						(call $function (i32.load (call $import-record (global.get $pending-import))))
					)
				)
				;; Preserve suspension so a wide caller can supply the correct result instead.
				(if
					(i32.or
						(i32.ge_u (global.get $last-results) (i32.const 2))
						(i32.ge_u (local.get $type) (i32.const 2))
					)
					(then
						(global.set $error (i32.const M4_ERR_SUCCESS))
						(call $fail (i32.const M4_ERR_HOST_VALUE_TYPE))
						(return (i32.const 0))
					)
				)
			)
		)
		(i32.wrap_i64 (call $resume64 (i64.extend_i32_s (local.get $value)) (local.get $failed)))
	)

	;; Grow the sole logical guest memory from a host callback without reentering guest dispatch.
	(func (export "grow_guest_memory")
		(param $delta i32)
		(result i32)

		;; Growth requires a successfully loaded module with a declared memory.
		(if (i32.or (i32.eqz (global.get $ready)) (i32.eqz (global.get $memory-present)))
			(then
				(return (i32.const -1))
			)
		)
		(call $use-memory (i32.const 0))
		(call $guest-grow (local.get $delta))
	)
