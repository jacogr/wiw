	;; Reserve instruction, folding-frame and operand regions after the source.
	;; Also reserve module/global/segment records, controls, calls, branch tables and decoded data.
	;; Return 1 on success, or record a resource error and return 0.
	(func $prepare
		(result i32)
		(local $base i64)
		(local $required i64)
		(local $available i64)
		(local $pages i32)

		;; The 512-function declaration bitmap occupies reserved static bytes below guest source.
		(call $zero-bytes (i32.const 3920) (i32.const 64))
		(global.set $start-state (i32.const 0))
		(global.set $start-function (i32.const 0))
		(global.set $start-length (i32.const 0))
		(global.set $start-offset (i32.const 0))
		(global.set $signature-count (i32.const 0))
		(global.set $indirect-type-count (i32.const 0))
		(global.set $element-count (i32.const 0))
		(global.set $element-entry-count (i32.const 0))
		(global.set $result-shape-count (i32.const 0))
		(global.set $guest-table-present (i32.const 0))
		(global.set $guest-table-size (i32.const 0))
		(global.set $guest-table-name (i32.const 0))
		(global.set $guest-table-name-length (i32.const 0))
		(global.set $code-count (i32.const 0))
		(global.set $depth (i32.const 0))
		(global.set $function-count (i32.const 0))
		(global.set $export-count (i32.const 0))
		(global.set $table-count (i32.const 0))
		(global.set $global-count (i32.const 0))
		(global.set $segment-count (i32.const 0))
		(global.set $data-count (i32.const 0))
		(global.set $memory-present (i32.const 0))
		(global.set $memory-name (i32.const 0))
		(global.set $memory-name-length (i32.const 0))
		(global.set $guest-pages (i32.const 0))
		(global.set $import-count (i32.const 0))
		(global.set $parsing-import (i32.const 0))
		(global.set $definitions-started (i32.const 0))
		(global.set $pending-import (i32.const -1))
		(global.set $resuming (i32.const 0))
		(local.set $base
			(i64.and (i64.add (i64.extend_i32_u (global.get $end)) (i64.const 15)) (i64.const -16))
		)
		(local.set $required (i64.add (local.get $base) (i64.const OWNED_BYTES)))
		;; Reject layouts whose end cannot be represented by an i32 byte address.
		(if (i64.gt_u (local.get $required) (i64.const 4294967295))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(local.set $available (i64.mul (i64.extend_i32_u (memory.size)) (i64.const 65536)))
		;; Grow only when the reserved regions do not fit in the existing memory.
		(if (i64.gt_u (local.get $required) (local.get $available))
			(then
				(local.set $pages
					(i32.wrap_i64
						(i64.div_u
							(i64.add (i64.sub (local.get $required) (local.get $available)) (i64.const 65535))
							(i64.const 65536)
						)
					)
				)
				;; A failed memory growth is a resource error rather than a native trap.
				(if (i32.eq (memory.grow (local.get $pages)) (i32.const -1))
					(then
						(call $fail (i32.const 6))
						(return (i32.const 0))
					)
				)
			)
		)
		(global.set $code-base (i32.wrap_i64 (local.get $base)))
		(global.set $frame-base (i32.add (global.get $code-base) (i32.const FRAME_OFFSET)))
		(global.set $stack-base (i32.add (global.get $code-base) (i32.const STACK_OFFSET)))
		(global.set $function-base (i32.add (global.get $code-base) (i32.const FUNCTION_OFFSET)))
		(global.set $local-name-base
			(i32.add (global.get $code-base) (i32.const LOCAL_NAME_OFFSET))
		)
		(global.set $export-base (i32.add (global.get $code-base) (i32.const EXPORT_OFFSET)))
		(global.set $call-base (i32.add (global.get $code-base) (i32.const CALL_OFFSET)))
		(global.set $metadata-base (i32.add (global.get $code-base) (i32.const METADATA_OFFSET)))
		(global.set $control-base (i32.add (global.get $code-base) (i32.const CONTROL_OFFSET)))
		(global.set $table-base (i32.add (global.get $code-base) (i32.const TABLE_OFFSET)))
		(global.set $global-base (i32.add (global.get $code-base) (i32.const GLOBAL_OFFSET)))
		(global.set $segment-base (i32.add (global.get $code-base) (i32.const SEGMENT_OFFSET)))
		(global.set $data-base (i32.add (global.get $code-base) (i32.const DATA_OFFSET)))
		(global.set $import-base (i32.add (global.get $code-base) (i32.const IMPORT_OFFSET)))
		(global.set $local-type-base
			(i32.add (global.get $code-base) (i32.const LOCAL_TYPE_OFFSET))
		)
		(global.set $type-stack-base
			(i32.add (global.get $code-base) (i32.const TYPE_STACK_OFFSET))
		)
		(global.set $result-shape-base
			(i32.add (global.get $code-base) (i32.const RESULT_SHAPE_OFFSET))
		)
		(global.set $stack-high-base
			(i32.add (global.get $code-base) (i32.const STACK_HIGH_OFFSET))
		)
		(global.set $call-high-base
			(i32.add (global.get $code-base) (i32.const CALL_HIGH_OFFSET))
		)
		(global.set $argument-high-base
			(i32.add (global.get $code-base) (i32.const ARGUMENT_HIGH_OFFSET))
		)
		(global.set $argument-base (i32.add (global.get $code-base) (i32.const ARGUMENT_OFFSET)))
		(global.set $signature-base
			(i32.add (global.get $code-base) (i32.const SIGNATURE_OFFSET))
		)
		(global.set $function-type-base
			(i32.add (global.get $code-base) (i32.const FUNCTION_TYPE_OFFSET))
		)
		(global.set $guest-table-arena
			(i32.add (global.get $code-base) (i32.const GUEST_TABLE_OFFSET))
		)
		(global.set $element-base (i32.add (global.get $code-base) (i32.const ELEMENT_OFFSET)))
		(global.set $element-entry-base
			(i32.add (global.get $code-base) (i32.const ELEMENT_ENTRY_OFFSET))
		)
		(global.set $fp-a-base (i32.add (global.get $code-base) (i32.const FP_A_OFFSET)))
		(global.set $fp-b-base (i32.add (global.get $code-base) (i32.const FP_B_OFFSET)))
		(global.set $fp-t-base (i32.add (global.get $code-base) (i32.const FP_T_OFFSET)))
		(global.set $host-base (i32.wrap_i64 (local.get $required)))
		;; Reset optional descriptor fields when reload reuses an existing arena layout.
		(call $zero-bytes (global.get $segment-base) (i32.const 6144))
		(call $zero-bytes (global.get $import-base) (i32.const 32768))
		(call $zero-bytes (global.get $global-base) (i32.const 10240))
		(call $zero-bytes (global.get $signature-base) (i32.const 98304))
		(i32.const 1)
	)

	;; Append an instruction record: opcode, immediate, source offset and opcode-specific extra data.
	;; Offsets 0/4/8/12: opcode, immediate, source offset, reference length/table size/alignment.
	;; Calls are resolved and all stack effects validated after every function signature is known.
	(func $emit
		(param $op i32)
		(param $immediate i32)
		(param $offset i32)
		(param $name-length i32)
		(local $record i32)

		;; Do not append incomplete instructions after an earlier parser failure.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Stop before the instruction region can overwrite folding frames.
		(if (i32.ge_u (global.get $code-count) (i32.const CAP_INSTRUCTIONS))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $record
			(i32.add (global.get $code-base) (i32.mul (global.get $code-count) (i32.const 16)))
		)
		(i32.store (local.get $record) (local.get $op))
		(i32.store offset=4 (local.get $record) (local.get $immediate))
		(i32.store offset=8 (local.get $record) (local.get $offset))
		(i32.store offset=12 (local.get $record) (local.get $name-length))
		(global.set $code-count (i32.add (global.get $code-count) (i32.const 1)))
	)
