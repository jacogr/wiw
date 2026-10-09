	;; Set one optional quota before a load can retain arena addresses.
	(func (export "configure_capacity") (param $kind i32) (param $value i32) (result i32)
		;; A loaded instance cannot replace any existing resource or parser arena.
		(if (global.get $code-base) (then (return (i32.const M4_ERR_INVALID_RESUME))))
		;; instructions: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_INSTRUCTIONS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_INSTRUCTIONS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_INSTRUCTIONS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $instruction-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; operands: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_OPERANDS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_OPERANDS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_OPERANDS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $operand-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; controls: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_CONTROLS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_CONTROLS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_CONTROLS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $control-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; syntaxDepth: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_SYNTAX_DEPTH))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_SYNTAX_DEPTH)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_SYNTAX_DEPTH)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $syntax-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; auxiliarySlots: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_AUXILIARY_SLOTS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_AUXILIARY_SLOTS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_AUXILIARY_SLOTS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $auxiliary-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; imports: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_IMPORTS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_IMPORTS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_IMPORTS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $import-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; types: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_TYPES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_TYPES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_TYPES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $type-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; indirectTypes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_INDIRECT_TYPES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_INDIRECT_TYPES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_INDIRECT_TYPES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $indirect-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; referenceTypes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_REFERENCE_TYPES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_REFERENCE_TYPES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_REFERENCE_TYPES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $reference-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; fields: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_FIELDS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_FIELDS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_FIELDS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $field-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; tags: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_TAGS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_TAGS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_TAGS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $tag-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; memories: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_MEMORIES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_MEMORIES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_MEMORIES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $memory-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; tables: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_TABLES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_TABLES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_TABLES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $table-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; tableEntries: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_TABLE_ENTRIES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_TABLE_ENTRIES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_TABLE_ENTRIES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $table-entry-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; dataSegments: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_DATA_SEGMENTS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_DATA_SEGMENTS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_DATA_SEGMENTS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $segment-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; elementSegments: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_ELEMENT_SEGMENTS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_ELEMENT_SEGMENTS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_ELEMENT_SEGMENTS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $element-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; elementEntries: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_ELEMENT_ENTRIES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_ELEMENT_ENTRIES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_ELEMENT_ENTRIES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $element-entry-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; dataBytes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_DATA_BYTES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_DATA_BYTES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_DATA_BYTES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $data-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; resultShapes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_RESULT_SHAPES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_RESULT_SHAPES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_RESULT_SHAPES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $result-shape-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; gcHeapBytes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_GC_HEAP_BYTES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_GC_HEAP_BYTES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_GC_HEAP_BYTES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $gc-heap-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; gcMapBytes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_GC_MAP_BYTES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_GC_MAP_BYTES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_GC_MAP_BYTES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $gc-map-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; gcTemporaries: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_GC_TEMPORARIES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_GC_TEMPORARIES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_GC_TEMPORARIES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $gc-temp-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; binaryTextBytes: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_BINARY_TEXT_BYTES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_BINARY_TEXT_BYTES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_BINARY_TEXT_BYTES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $binary-text-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; typeComparisonDepth: keep the validated default layout as the minimum capacity.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_TYPE_COMPARISON_DEPTH))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_TYPE_COMPARISON_DEPTH)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_TYPE_COMPARISON_DEPTH)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $comparison-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; parameters: widened records are reserved before parsing starts.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_PARAMETERS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_PARAMETERS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_PARAMETERS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $parameter-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; results: widened records are reserved before parsing starts.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_RESULTS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_RESULTS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_RESULTS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $result-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; locals: widened records are reserved before parsing starts.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_LOCALS))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_LOCALS)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_LOCALS)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $local-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		;; floatLiteralBytes: widened records are reserved before parsing starts.
		(if (i32.eq (local.get $kind) (i32.const M4_LIMIT_ID_FLOAT_LITERAL_BYTES))
			(then
				;; Reject quotas outside this arena’s storage representation.
				(if (i32.or (i32.lt_u (local.get $value) (i32.const M4_LIMIT_DEFAULT_FLOAT_LITERAL_BYTES)) (i32.gt_u (local.get $value) (i32.const M4_LIMIT_MAX_FLOAT_LITERAL_BYTES)))
					(then (return (i32.const M4_ERR_INVALID_BUFFER))))
				(global.set $float-limit (local.get $value))
				(return (i32.const 0))
			)
		)
		(i32.const M4_ERR_INVALID_BUFFER)
	)

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
				(i32.or (i32.gt_u (local.get $functions) (i32.const M4_LIMIT_MAX_FUNCTIONS))
					(i32.gt_u (local.get $exports) (i32.const M4_LIMIT_MAX_EXPORTS)))
				(i32.or (i32.gt_u (local.get $globals) (i32.const M4_LIMIT_MAX_GLOBALS))
					(i32.or (i32.or (i32.eqz (local.get $calls))
						(i32.gt_u (local.get $calls) (i32.const M4_LIMIT_MAX_CALL_FRAMES)))
						(i32.gt_u (local.get $pages) (i32.const M4_LIMIT_MAX_MEMORY_PAGES))))
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
		(local.set $base (i32.and (i32.add (global.get $owned-end) (i32.const 15)) (i32.const -16)))
		(local.set $end
			(i64.and
				(i64.add (i64.add (i64.extend_i32_u (local.get $base)) (local.get $bytes)) (i64.const 15))
				(i64.const -16)
			)
		)
		;; Memory growth must succeed before any pointer or logical size changes.
		(if (i32.eqz (call $ensure-bytes (i64.add (local.get $end) (i64.const M4_HOST_SCRATCH_BYTES))))
			(then (call $fail (i32.const M4_ERR_RESOURCE_LIMIT)) (return (i32.const 0)))
		)
		(global.set $owned-end (i32.wrap_i64 (local.get $end)))
		(global.set $host-base (global.get $owned-end))
		(local.get $base)
	)

	;; Reserve optional larger arenas before any parser or guest retains their pointers.
	(func $prepare-capacities
		(result i32)

		(global.set $signature-bytes (i32.add (i32.const M4_SIGNATURE_HEADER_BYTES) (i32.shl (global.get $parameter-limit) (i32.const 2))))
		(global.set $local-bytes (i32.shl (global.get $local-limit) (i32.const 3)))
		(global.set $call-bytes (i32.add (global.get $local-bytes) (i32.const M4_CALL_HEADER_BYTES)))
		(global.set $call-root-offset (i32.add (global.get $local-bytes) (i32.const M4_CALL_ROOT_HEADER_OFFSET)))
		(global.set $shape-bytes (i32.add (i32.const M4_RESULT_SHAPE_HEADER_BYTES) (i32.shl (global.get $result-limit) (i32.const 2))))

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
		(if (i32.or (i32.gt_u (global.get $call-limit) (i32.const M4_CAP_CALLS)) (i32.gt_u (global.get $local-limit) (i32.const M4_CAP_LOCALS)))
			(then
				(global.set $call-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $call-limit)) (i64.extend_i32_u (global.get $call-bytes)))))
				(global.set $call-high-base (call $reserve-owned
					(i64.mul (i64.extend_i32_u (global.get $call-limit)) (i64.extend_i32_u (global.get $local-bytes)))))
			)
		)
		;; Reserve code-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $instruction-limit) (i32.const M4_LIMIT_DEFAULT_INSTRUCTIONS))
			(then
				(global.set $code-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $instruction-limit)) (i64.const 16))
					)
				)
			)
		)
		;; Reserve metadata-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $instruction-limit) (i32.const M4_LIMIT_DEFAULT_INSTRUCTIONS))
			(then
				(global.set $metadata-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $instruction-limit)) (i64.const 32))
					)
				)
			)
		)
		;; Reserve gc-map-index-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $instruction-limit) (i32.const M4_LIMIT_DEFAULT_INSTRUCTIONS))
			(then
				(global.set $gc-map-index-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $instruction-limit)) (i64.const 4))
					)
				)
			)
		)
		;; Reserve stack-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $operand-limit) (i32.const M4_LIMIT_DEFAULT_OPERANDS))
			(then
				(global.set $stack-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $operand-limit)) (i64.const 8))
					)
				)
			)
		)
		;; Reserve stack-high-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $operand-limit) (i32.const M4_LIMIT_DEFAULT_OPERANDS))
			(then
				(global.set $stack-high-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $operand-limit)) (i64.const 8))
					)
				)
			)
		)
		;; Reserve type-stack-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $operand-limit) (i32.const M4_LIMIT_DEFAULT_OPERANDS))
			(then
				(global.set $type-stack-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $operand-limit)) (i64.const 4))
					)
				)
			)
		)
		;; Reserve control-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $control-limit) (i32.const M4_LIMIT_DEFAULT_CONTROLS))
			(then
				(global.set $control-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $control-limit)) (i64.const 32))
					)
				)
			)
		)
		;; Reserve frame-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $syntax-limit) (i32.const M4_LIMIT_DEFAULT_SYNTAX_DEPTH))
			(then
				(global.set $frame-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $syntax-limit)) (i64.const 32))
					)
				)
			)
		)
		;; Reserve table-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $auxiliary-limit) (i32.const M4_LIMIT_DEFAULT_AUXILIARY_SLOTS))
			(then
				(global.set $table-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $auxiliary-limit)) (i64.const 4))
					)
				)
			)
		)
		;; Reserve import-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $import-limit) (i32.const M4_LIMIT_DEFAULT_IMPORTS))
			(then
				(global.set $import-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $import-limit)) (i64.const 32))
					)
				)
			)
		)
		;; Reserve signature-base before parser or guest records can retain any pointer.
		(if (i32.or (i32.gt_u (global.get $parameter-limit) (i32.const M4_LIMIT_DEFAULT_PARAMETERS)) (i32.or (i32.gt_u (global.get $type-limit) (i32.const M4_LIMIT_DEFAULT_TYPES)) (i32.gt_u (global.get $indirect-limit) (i32.const M4_LIMIT_DEFAULT_INDIRECT_TYPES))))
			(then
				(global.set $signature-base
					(call $reserve-owned
						(i64.mul
							(i64.add
								(i64.extend_i32_u (global.get $type-limit))
								(i64.extend_i32_u (global.get $indirect-limit))
							)
							(i64.extend_i32_u (global.get $signature-bytes))
						)
					)
				)
			)
		)
		;; Reserve heap-type-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $type-limit) (i32.const M4_LIMIT_DEFAULT_TYPES))
			(then
				(global.set $heap-type-base
					(call $reserve-owned (i64.mul (i64.extend_i32_u (global.get $type-limit)) (i64.const 64)))
				)
			)
		)
		;; Reserve reference-type-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $reference-limit) (i32.const M4_LIMIT_DEFAULT_REFERENCE_TYPES))
			(then
				(global.set $reference-type-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $reference-limit)) (i64.const 32))
					)
				)
			)
		)
		;; Reserve field-type-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $field-limit) (i32.const M4_LIMIT_DEFAULT_FIELDS))
			(then
				(global.set $field-type-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $field-limit)) (i64.const 16))
					)
				)
			)
		)
		;; Reserve tag-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $tag-limit) (i32.const M4_LIMIT_DEFAULT_TAGS))
			(then
				(global.set $tag-base
					(call $reserve-owned (i64.mul (i64.extend_i32_u (global.get $tag-limit)) (i64.const 64)))
				)
			)
		)
		;; Reserve memory-arena before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $memory-limit) (i32.const M4_LIMIT_DEFAULT_MEMORIES))
			(then
				(global.set $memory-arena
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $memory-limit)) (i64.const 64))
					)
				)
			)
		)
		;; Reserve guest-table-arena before parser or guest records can retain any pointer.
		(if (i32.or (i32.gt_u (global.get $table-limit) (i32.const M4_LIMIT_DEFAULT_TABLES)) (i32.gt_u (global.get $table-entry-limit) (i32.const M4_LIMIT_DEFAULT_TABLE_ENTRIES)))
			(then
				(global.set $guest-table-arena
					(call $reserve-owned
						(i64.mul
							(i64.extend_i32_u (global.get $table-limit))
							(i64.add
								(i64.mul (i64.extend_i32_u (global.get $table-entry-limit)) (i64.const 4))
								(i64.const 64)
							)
						)
					)
				)
			)
		)
		;; Reserve segment-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $segment-limit) (i32.const M4_LIMIT_DEFAULT_DATA_SEGMENTS))
			(then
				(global.set $segment-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $segment-limit)) (i64.const 48))
					)
				)
			)
		)
		;; Reserve element-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $element-limit) (i32.const M4_LIMIT_DEFAULT_ELEMENT_SEGMENTS))
			(then
				(global.set $element-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $element-limit)) (i64.const 64))
					)
				)
			)
		)
		;; Reserve element-entry-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $element-entry-limit) (i32.const M4_LIMIT_DEFAULT_ELEMENT_ENTRIES))
			(then
				(global.set $element-entry-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $element-entry-limit)) (i64.const 16))
					)
				)
			)
		)
		;; Reserve data-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $data-limit) (i32.const M4_LIMIT_DEFAULT_DATA_BYTES))
			(then (global.set $data-base (call $reserve-owned (i64.extend_i32_u (global.get $data-limit)))))
		)
		;; Reserve result-shape-base before parser or guest records can retain any pointer.
		(if (i32.or (i32.gt_u (global.get $result-shape-limit) (i32.const M4_LIMIT_DEFAULT_RESULT_SHAPES)) (i32.gt_u (global.get $result-limit) (i32.const M4_LIMIT_DEFAULT_RESULTS)))
			(then
				(global.set $result-shape-base
					(call $reserve-owned
						(i64.mul
							(i64.extend_i32_u (global.get $result-shape-limit))
							(i64.extend_i32_u (global.get $shape-bytes))
						)
					)
				)
			)
		)
		;; Reserve gc-object-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $gc-heap-limit) (i32.const M4_LIMIT_DEFAULT_GC_HEAP_BYTES))
			(then (global.set $gc-object-base (call $reserve-owned (i64.extend_i32_u (global.get $gc-heap-limit)))))
		)
		;; Reserve gc-queue-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $gc-heap-limit) (i32.const M4_LIMIT_DEFAULT_GC_HEAP_BYTES))
			(then
				(global.set $gc-queue-base
					(call $reserve-owned
						(i64.div_u (i64.extend_i32_u (global.get $gc-heap-limit)) (i64.const 4))
					)
				)
			)
		)
		;; Reserve gc-map-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $gc-map-limit) (i32.const M4_LIMIT_DEFAULT_GC_MAP_BYTES))
			(then (global.set $gc-map-base (call $reserve-owned (i64.extend_i32_u (global.get $gc-map-limit)))))
		)
		;; Reserve gc-temp-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $gc-temp-limit) (i32.const M4_LIMIT_DEFAULT_GC_TEMPORARIES))
			(then
				(global.set $gc-temp-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $gc-temp-limit)) (i64.const 8))
					)
				)
			)
		)
		;; Reserve type-comparison-base before parser or guest records can retain any pointer.
		(if (i32.gt_u (global.get $comparison-limit) (i32.const M4_LIMIT_DEFAULT_TYPE_COMPARISON_DEPTH))
			(then
				(global.set $type-comparison-base
					(call $reserve-owned
						(i64.mul (i64.extend_i32_u (global.get $comparison-limit)) (i64.const 8))
					)
				)
			)
		)
		(global.set $table-record-bytes (i32.add (i32.mul (global.get $table-entry-limit) (i32.const 4)) (i32.const 64)))
		;; Type hashes remain sparse enough for every configured declared type.
		(if (i32.gt_u (global.get $type-limit) (i32.const M4_CAP_TYPES))
			(then
				(global.set $type-name-mask (i32.const M4_TYPE_NAME_INDEX_MASK))
				;; Finish once the sparse name index covers the configured namespace.
				(block $ready
					;; Doubling preserves the hash table's power-of-two mask.
					(loop $grow
						(br_if $ready (i32.gt_u (global.get $type-name-mask) (i32.mul (global.get $type-limit) (i32.const 2))))
						(global.set $type-name-mask
							(i32.sub
								(i32.shl (i32.add (global.get $type-name-mask) (i32.const 1)) (i32.const 1))
								(i32.const 1)
							)
						)
						(br $grow)
					)
				)
				(global.set $type-name-index
					(call $reserve-owned
						(i64.mul
							(i64.extend_i32_u (i32.add (global.get $type-name-mask) (i32.const 1)))
							(i64.const 16)
						)
					)
				)
			)
		)
		;; Additional parameter/result transport slots preserve full vector high halves.
		(if (i32.or (i32.gt_u (global.get $parameter-limit) (i32.const M4_LIMIT_DEFAULT_PARAMETERS)) (i32.gt_u (global.get $result-limit) (i32.const M4_LIMIT_DEFAULT_RESULTS)))
			(then
				(global.set $argument-base
					(call $reserve-owned
						(i64.shl (i64.extend_i32_u (global.get $parameter-limit)) (i64.const 3))
					)
				)
				(global.set $argument-high-base (call $reserve-owned (i64.shl (i64.extend_i32_u
					(select (global.get $parameter-limit) (global.get $result-limit) (i32.gt_u (global.get $parameter-limit) (global.get $result-limit)))) (i64.const 3))))
			)
		)
		;; Each function's local names/types and validation initialization scratch share the configured stride.
		(if (i32.gt_u (global.get $local-limit) (i32.const M4_CAP_LOCALS))
			(then
				(global.set $local-name-base
					(call $reserve-owned
						(i64.mul (i64.const M4_CAP_FUNCTIONS) (i64.extend_i32_u (global.get $local-bytes)))
					)
				)
				(global.set $local-type-base
					(call $reserve-owned
						(i64.mul
							(i64.const M4_CAP_FUNCTIONS)
							(i64.shl (i64.extend_i32_u (global.get $local-limit)) (i64.const 2))
						)
					)
				)
				(global.set $local-init-base
					(call $reserve-owned (i64.shl (i64.extend_i32_u (global.get $local-limit)) (i64.const 2)))
				)
				;; Finish once the sparse name index covers the configured namespace.
				(block $ready
					;; Enough hash slots keep local identifiers collision-safe at the configured bound.
					(loop $grow
						(br_if $ready (i32.gt_u (global.get $local-name-mask) (i32.mul (global.get $local-limit) (i32.const 2))))
						(global.set $local-name-mask
							(i32.sub
								(i32.shl (i32.add (global.get $local-name-mask) (i32.const 1)) (i32.const 1))
								(i32.const 1)
							)
						)
						(br $grow)
					)
				)
				(global.set $local-name-index
					(call $reserve-owned
						(i64.shl
							(i64.extend_i32_u (i32.add (global.get $local-name-mask) (i32.const 1)))
							(i64.const 4)
						)
					)
				)
			)
		)
		;; Longer exact literals need larger integer scratch, independent of guest linear memories.
		(if (i32.gt_u (global.get $float-limit) (i32.const M4_LIMIT_DEFAULT_FLOAT_LITERAL_BYTES))
			(then
				(global.set $big-limb-limit (i32.add (i32.div_u (global.get $float-limit) (i32.const 8)) (i32.const M4_FLOAT_LIMB_GUARD)))
				(global.set $fp-a-base
					(call $reserve-owned
						(i64.shl
							(i64.extend_i32_u (i32.add (global.get $big-limb-limit) (i32.const 1)))
							(i64.const 2)
						)
					)
				)
				(global.set $fp-b-base
					(call $reserve-owned
						(i64.shl
							(i64.extend_i32_u (i32.add (global.get $big-limb-limit) (i32.const 1)))
							(i64.const 2)
						)
					)
				)
				(global.set $fp-t-base
					(call $reserve-owned
						(i64.shl
							(i64.extend_i32_u (i32.add (global.get $big-limb-limit) (i32.const 1)))
							(i64.const 2)
						)
					)
				)
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

		(local.set $required (i64.add (local.get $end) (i64.const M4_HOST_SCRATCH_BYTES)))
		;; Initialized memories begin at a page boundary and remain packed after the growing metadata.
		(if (global.get $resources-allocated)
			(then
				(local.set $linear (i64.and (i64.add (local.get $end) (i64.const 65535)) (i64.const -65536)))
				(local.set $required (i64.add (local.get $linear)
					(i64.add (i64.extend_i32_u (i32.sub (global.get $host-base) (global.get $linear-base))) (i64.const M4_HOST_SCRATCH_BYTES))))
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
					(i64.add (i64.const 96) (i64.add (i64.extend_i32_u (global.get $local-bytes)) (i64.shl (i64.extend_i32_u (global.get $local-limit)) (i64.const 2)))))
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
		(local.set $types (i32.add (local.get $names) (i32.mul (local.get $capacity) (global.get $local-bytes))))
		(local.set $metadata
			(i32.add
				(local.get $types)
				(i32.mul (local.get $capacity) (i32.shl (global.get $local-limit) (i32.const 2)))
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
			(i32.mul (global.get $function-count) (i32.shl (global.get $local-limit) (i32.const 2))))
		(memory.copy (local.get $names) (global.get $local-name-base)
			(i32.mul (global.get $function-count) (global.get $local-bytes)))
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
