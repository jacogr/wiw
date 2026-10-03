	;; Parse a sequence of function references into bounded element records, preserving forward names.
	(func $element-functions
		(param $record i32)
		(local $entry i32)
		(local $value i32)
		(local $length i32)

		(i32.store offset=4 (local.get $record) (global.get $element-entry-count))
		;; Optional func marks a function-index segment; expression-based segments are outside this subset.
		(if (call $is-word (i32.const 6) (i32.const 4))
			(then
				(call $next)
			)
		)
		;; End the segment on its closing parenthesis or the first parser failure.
		(block $done
			;; Append references without requiring their functions to have been declared yet.
			(loop $refs
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $kind) (i32.const 2)))
				;; Element entries have an independent 4096-slot capacity.
				(if (i32.ge_u (global.get $element-entry-count) (i32.const 4096))
					(then
						(call $fail (i32.const 6))
						(return)
					)
				)
				(local.set $entry
					(i32.add
						(global.get $element-entry-base)
						(i32.mul (global.get $element-entry-count) (i32.const 16))
					)
				)
				(i32.store offset=8 (local.get $entry) (global.get $tok))
				(local.set $length (i32.const 0))
				;; Retain named references for resolution against the completed function namespace.
				(if (call $named)
					(then
						(local.set $value (global.get $tok))
						(local.set $length (global.get $len))
						(call $next)
					)
					;; Numeric indices are validated after parsing all function definitions/imports.
					(else
						(local.set $value (call $index))
					)
				)
				(i32.store (local.get $entry) (local.get $value))
				(i32.store offset=4 (local.get $entry) (local.get $length))
				(global.set $element-entry-count
					(i32.add (global.get $element-entry-count) (i32.const 1))
				)
				(i32.store offset=8
					(local.get $record)
					(i32.add (i32.load offset=8 (local.get $record)) (i32.const 1))
				)
				(br $refs)
			)
		)
		(call $expect (i32.const 2))
	)

	;; Allocate a zeroed active-segment descriptor and preserve its source offset for initialization errors.
	(func $new-element
		(result i32)
		(local $record i32)

		;; Segment descriptors are bounded independently from their referenced entries.
		(if (i32.ge_u (global.get $element-count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(local.set $record
			(i32.add (global.get $element-base) (i32.mul (global.get $element-count) (i32.const 32)))
		)
		(call $zero-bytes (local.get $record) (i32.const 32))
		(i32.store offset=12 (local.get $record) (global.get $tok))
		(global.set $element-count (i32.add (global.get $element-count) (i32.const 1)))
		(local.get $record)
	)

	;; Parse one active default-table element segment with an i32 literal offset.
	(func $parse-element
		(local $record i32)

		(local.set $record (call $new-element))
		;; A failed descriptor allocation must not write through a null record.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(call $next)
		(call $segment-target (local.get $record))
		(i32.store (local.get $record) (call $initializer))
		(i32.store offset=28 (local.get $record) (global.get $initializer-reference))
		(call $element-functions (local.get $record))
	)

	;; Parse the sole funcref table, including the inline-element abbreviation and optional exports.
	(func $parse-table
		(local $record i32)
		(local $offset i32)

		;; Multiple tables and imported tables remain outside the MVP guest subset.
		(if (global.get $guest-table-present)
			(then
				(call $fail (i32.const 2))
				(return)
			)
		)
		(local.set $offset (global.get $tok))
		(global.set $guest-table-present (i32.const 1))
		(call $next)
		;; A table identifier has its own namespace, independent of memory and functions.
		(if (call $named)
			(then
				(global.set $guest-table-name (global.get $tok))
				(global.set $guest-table-name-length (global.get $len))
				(call $next)
			)
		)
		(call $resource-exports (i32.const 3) (i32.const 0))
		;; Inline elements fix both minimum and maximum to the number of references.
		(if (call $is-word (i32.const 3845) (i32.const 7))
			(then
				(call $next)
				(call $expect (i32.const 1))
				(local.set $record (call $new-element))
				;; Preserve allocation failures before attempting to populate the segment.
				(if (global.get $error)
					(then
						(return)
					)
				)
				(call $word (i32.const 3852) (i32.const 4))
				(call $element-functions (local.get $record))
				(global.set $guest-table-size (i32.load offset=8 (local.get $record)))
				(global.set $guest-table-max (global.get $guest-table-size))
			)
			;; A regular declaration supplies unsigned entry limits followed by funcref.
			(else
				(global.set $guest-table-size (call $index))
				(global.set $guest-table-max (i32.const -1))
				;; An optional second numeric limit supplies the maximum.
				(if (i32.eqz (call $is-word (i32.const 3845) (i32.const 7)))
					(then
						(global.set $guest-table-max (call $index))
					)
				)
				(call $word (i32.const 3845) (i32.const 7))
			)
		)
		(call $expect (i32.const 2))
		(call $finish-resource-declaration (i32.const 3) (i32.const 0))
		;; Declared maxima cannot be smaller than initial table sizes.
		(if (i32.gt_u (global.get $guest-table-size) (global.get $guest-table-max))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const 26))
			)
		)
		;; Actual initial storage is bounded even when a larger maximum is declared.
		(if (i32.gt_u (global.get $guest-table-size) (i32.const 4096))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const 6))
			)
		)
	)

	;; Resolve every element reference, including segments that will later fail initialization bounds.
	(func $resolve-elements
		(local $i i32)
		(local $entry i32)

		;; A segment requires the default table even when it contains no entries.
		(if
			(i32.and
				(i32.ne (global.get $element-count) (i32.const 0))
				(i32.eqz (global.get $guest-table-present))
			)
			(then
				(call $fail (i32.const 10))
				(return)
			)
		)
		;; Finish once all entry records contain validated numeric function indices.
		(block $done
			;; Names may target imported or defined functions that appear later in source order.
			(loop $entries
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $element-entry-count)))
				(local.set $entry
					(i32.add (global.get $element-entry-base) (i32.mul (local.get $i) (i32.const 16)))
				)
				(i32.store
					(local.get $entry)
					(call $target
						(i32.load (local.get $entry))
						(i32.load offset=4 (local.get $entry))
						(i32.load offset=8 (local.get $entry))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Initialize table entries to null, then apply active segments in source order with unsigned bounds checks.
	(func $allocate-table
		(local $i i32)
		(local $j i32)
		(local $record i32)
		(local $start i32)
		(local $count i32)

		;; Reload discards earlier table contents and creates a fresh null-filled table.
		(block $cleared
			;; Null is represented by -1 and cannot alias a valid function index.
			(loop $clear
				(br_if $cleared (i32.eq (local.get $i) (global.get $guest-table-size)))
				(i32.store
					(i32.add (global.get $guest-table-base) (i32.mul (local.get $i) (i32.const 4)))
					(i32.const -1)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $clear)
			)
		)
	)

	;; Apply active elements after the host has installed imported table entries.
	(func $apply-elements
		(local $i i32)
		(local $j i32)
		(local $record i32)
		(local $start i32)
		(local $count i32)

		(local.set $i (i32.const 0))
		;; Stop after all segments or immediately when one fails initialization.
		(block $done
			;; Later overlapping segments replace the earlier function references.
			(loop $segments
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $element-count)))
				(local.set $record
					(i32.add (global.get $element-base) (i32.mul (local.get $i) (i32.const 32)))
				)
				(drop
					(call $resource-target
						(i32.const 3)
						(i32.load offset=16 (local.get $record))
						(i32.load offset=20 (local.get $record))
						(i32.load offset=24 (local.get $record))
					)
				)
				;; Target validation precedes runtime bounds checks for active segments.
				(if (global.get $error)
					(then
						(return)
					)
				)
				;; Evaluate imported-global offsets only after the host binds their values.
				(if (i32.load offset=28 (local.get $record))
					(then
						(i32.store
							(local.get $record)
							(i32.wrap_i64
								(i64.load offset=24
									(call $global-record (i32.sub (i32.load offset=28 (local.get $record)) (i32.const 1)))
								)
							)
						)
					)
				)
				(local.set $start (i32.load (local.get $record)))
				(local.set $count (i32.load offset=8 (local.get $record)))
				;; An empty segment still requires its offset at or before the table's logical end.
				(if
					(i64.gt_u
						(i64.add (i64.extend_i32_u (local.get $start)) (i64.extend_i32_u (local.get $count)))
						(i64.extend_i32_u (global.get $guest-table-size))
					)
					(then
						(global.set $tok (i32.load offset=12 (local.get $record)))
						(call $fail (i32.const 27))
						(return)
					)
				)
				(local.set $j (i32.const 0))
				;; Finish after copying this segment's validated function indices.
				(block $copied
					;; Table and element storage are independent from branch-table records.
					(loop $copy
						(br_if $copied (i32.eq (local.get $j) (local.get $count)))
						(i32.store
							(i32.add
								(global.get $guest-table-base)
								(i32.mul (i32.add (local.get $start) (local.get $j)) (i32.const 4))
							)
							(i32.load
								(i32.add
									(global.get $element-entry-base)
									(i32.mul (i32.add (i32.load offset=4 (local.get $record)) (local.get $j)) (i32.const 16))
								)
							)
						)
						(local.set $j (i32.add (local.get $j) (i32.const 1)))
						(br $copy)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $segments)
			)
		)
	)

	;; Initialize a standalone table and then apply its active element segments.
	(func $instantiate-table
		(call $allocate-table)
		(call $apply-elements)
	)
