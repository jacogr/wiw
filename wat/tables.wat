	;; Locate one table descriptor followed by its independent fixed entry arena.
	(func $guest-table-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $guest-table-arena) (i32.mul (local.get $index) (i32.const 16448)))
	)

	;; Follow a trusted import alias to its canonical table descriptor within this instance.
	(func $canonical-table-record
		(param $index i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $guest-table-record (local.get $index)))
		;; Aliases are installed directly to the first binding, without recursive chains.
		(if (i32.load offset=20 (local.get $record))
			(then
				(return
					(call $guest-table-record
						(i32.sub (i32.load offset=20 (local.get $record)) (i32.const 1))
					)
				)
			)
		)
		(local.get $record)
	)

	;; Select a table's cached descriptor fields for scalar instruction execution.
	(func $use-table
		(param $index i32)
		(local $record i32)

		(local.set $record (call $canonical-table-record (local.get $index)))
		(global.set $guest-table-index
			(i32.div_u
				(i32.sub (local.get $record) (global.get $guest-table-arena))
				(i32.const 16448)
			)
		)
		(global.set $guest-table-base (i32.add (local.get $record) (i32.const 64)))
		(global.set $guest-table-name (i32.load (local.get $record)))
		(global.set $guest-table-name-length (i32.load offset=4 (local.get $record)))
		(global.set $guest-table-size (i32.load offset=8 (local.get $record)))
		(global.set $guest-table-max (i32.load offset=12 (local.get $record)))
		(global.set $guest-table-type (i32.load offset=16 (local.get $record)))
	)

	;; Resolve a table name within its own module namespace.
	(func $find-table
		(param $name i32)
		(param $length i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Search every declared table without changing the selected runtime table.
		(block $done
			;; Identifiers compare exact source bytes and lengths.
			(loop $names
				(br_if $done (i32.eq (local.get $i) (global.get $guest-table-present)))
				(local.set $record (call $guest-table-record (local.get $i)))
				;; Anonymous tables cannot match a nonempty identifier.
				(if
					(i32.and
						(i32.eq (local.get $length) (i32.load offset=4 (local.get $record)))
						(call $equal (local.get $name) (i32.load (local.get $record)) (local.get $length))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(i32.const -1)
	)

	;; Locate one element descriptor with name, mode, live length and reference type.
	(func $element-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $element-base) (i32.mul (local.get $index) (i32.const 64)))
	)

	;; Read an unsigned function index or preserve a forward name and its length.
	(func $function-reference
		(result i32)
		(local $value i32)

		(global.set $immediate-length (i32.const 0))
		;; Source-backed names are resolved only after the full function namespace exists.
		(if (call $named)
			(then
				(local.set $value (global.get $tok))
				(global.set $immediate-length (global.get $len))
				(call $next)
				(return (local.get $value))
			)
		)
		(call $index)
	)

	;; Mark a validated function as declared by a global initializer, export or element segment.
	(func $declare-function
		(param $index i32)
		(local $address i32)

		;; Failed lookups cannot write outside the fixed 512-function bitmap.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $address
			(i32.add (i32.const 3920) (i32.shr_u (local.get $index) (i32.const 3)))
		)
		(i32.store8
			(local.get $address)
			(i32.or
				(i32.load8_u (local.get $address))
				(i32.shl (i32.const 1) (i32.and (local.get $index) (i32.const 7)))
			)
		)
	)

	;; Resolve an element index or name in its own source-order namespace.
	(func $element-target
		(param $value i32)
		(param $length i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Numeric references include active, passive and declarative segments.
		(if (i32.eqz (local.get $length))
			(then
				;; Missing segments are reference errors even when the instruction is unreachable.
				(if (i32.ge_u (local.get $value) (global.get $element-count))
					(then
						(call $fail (i32.const 10))
					)
				)
				(return (local.get $value))
			)
		)
		;; Finish after all names have been searched without a match.
		(block $done
			;; Segment names are independent of functions, tables and data names.
			(loop $names
				(br_if $done (i32.eq (local.get $i) (global.get $element-count)))
				(local.set $record (call $element-record (local.get $i)))
				;; Match the full identifier length and source-backed bytes.
				(if
					(i32.and
						(i32.eq (local.get $length) (i32.load offset=36 (local.get $record)))
						(call $equal
							(local.get $value)
							(i32.load offset=32 (local.get $record))
							(local.get $length)
						)
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(call $fail (i32.const 10))
		(i32.const 0)
	)

	;; Parse a segment initializer list, including index lists, nulls, globals and item wrappers.
	(func $element-functions
		(param $record i32)
		(local $entry i32)
		(local $expression i32)
		(local $wrapper i32)
		(local $nested i32)
		(local $op i32)
		(local $type i32)

		(i32.store offset=4 (local.get $record) (global.get $element-entry-count))
		;; Legacy func lists contain bare indices; typed lists contain constant expressions.
		(if (call $is-word (i32.const 6) (i32.const 4))
			(then
				(call $next)
			)
			;; An explicit reference type introduces the expression form.
			(else
				;; Inline table abbreviations may omit the funcref annotation before expressions.
				(if
					(i32.or
						(call $is-word (i32.const 3845) (i32.const 7))
						(call $is-word (i32.const 3893) (i32.const 9))
					)
					(then
						(i32.store offset=48 (local.get $record) (call $value-type))
						(local.set $expression (i32.const 1))
					)
					;; Parenthesized entries in an inline table are implicitly funcref expressions.
					(else
						(local.set $expression (i32.eq (global.get $kind) (i32.const 1)))
					)
				)
			)
		)
		;; Finish at the segment close or the first parser error.
		(block $done
			;; Every initializer reserves one bounded entry, preserving forward references.
			(loop $entries
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (global.get $kind) (i32.const 2)))
				;; Element entries have their own fixed capacity.
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
				(call $zero-bytes (local.get $entry) (i32.const 16))
				(i32.store offset=8 (local.get $entry) (global.get $tok))
				(local.set $wrapper (i32.const 0))
				(local.set $nested (i32.const 0))
				;; Expressions use a parenthesized ref.func/ref.null/global.get, optionally inside item.
				(if (local.get $expression)
					(then
						(call $expect (i32.const 1))
						;; Item accepts either a folded constant expression or its flat instruction spelling.
						(if (call $is-word (i32.const 3915) (i32.const 4))
							(then
								(local.set $wrapper (i32.const 1))
								(call $next)
								;; Retain an additional close only for a nested folded item.
								(if (i32.eq (global.get $kind) (i32.const 1))
									(then
										(local.set $nested (i32.const 1))
										(call $next)
									)
								)
							)
						)
						(local.set $op (call $opcode))
						;; Function expressions implicitly declare their target after forward resolution.
						(if (i32.eq (local.get $op) (i32.const 195))
							(then
								;; A function expression must belong to a funcref list.
								(if (i32.ne (i32.load offset=48 (local.get $record)) (global.get $guest-table-type))
									(then
										(call $fail (i32.const 7))
									)
								)
								(call $next)
								(i32.store (local.get $entry) (call $function-reference))
								(i32.store offset=4 (local.get $entry) (global.get $immediate-length))
							)
							;; Null and imported-global expressions preserve the list's exact reference type.
							(else
								;; Nulls retain -1 as the table-storage sentinel.
								(if (i32.eq (local.get $op) (i32.const 193))
									(then
										(call $next)
										(local.set $type (call $reference-type))
										;; Mixed function/external nulls are invalid constant-expression types.
										(if (i32.ne (local.get $type) (i32.load offset=48 (local.get $record)))
											(then
												(call $fail (i32.const 7))
											)
										)
										(i32.store (local.get $entry) (i32.const -1))
										(i32.store offset=12 (local.get $entry) (i32.const 193))
									)
									;; Imported immutable globals supply their reference after bindings are installed.
									(else
										;; Other expressions cannot initialize element entries.
										(if (i32.eq (local.get $op) (i32.const 49))
											(then
												(call $read-initializer-global (i32.load offset=48 (local.get $record)))
												(i32.store (local.get $entry) (i32.sub (global.get $initializer-reference) (i32.const 1)))
												(i32.store offset=12 (local.get $entry) (i32.const 49))
											)
											;; Reject unknown constant operators without consuming following segment syntax.
											(else
												(call $fail (i32.const 1))
											)
										)
									)
								)
							)
						)
						(call $expect (i32.const 2))
						;; A nested item has one outer close in addition to its expression close.
						(if (i32.and (local.get $wrapper) (local.get $nested))
							(then
								(call $expect (i32.const 2))
							)
						)
					)
					;; Legacy bare indices use the same deferred function resolver.
					(else
						(i32.store (local.get $entry) (call $function-reference))
						(i32.store offset=4 (local.get $entry) (global.get $immediate-length))
					)
				)
				(global.set $element-entry-count
					(i32.add (global.get $element-entry-count) (i32.const 1))
				)
				(i32.store offset=8
					(local.get $record)
					(i32.add (i32.load offset=8 (local.get $record)) (i32.const 1))
				)
				(br $entries)
			)
		)
		(call $expect (i32.const 2))
		(i32.store offset=44
			(local.get $record)
			(select
				(i32.load offset=8 (local.get $record))
				(i32.const 0)
				(i32.eq (i32.load offset=40 (local.get $record)) (i32.const 1))
			)
		)
	)

	;; Allocate a zeroed segment descriptor with the default funcref type.
	(func $new-element
		(result i32)
		(local $record i32)

		;; Segment descriptors are bounded independently from entry storage.
		(if (i32.ge_u (global.get $element-count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(local.set $record (call $element-record (global.get $element-count)))
		(call $zero-bytes (local.get $record) (i32.const 64))
		(i32.store offset=12 (local.get $record) (global.get $tok))
		(i32.store offset=48 (local.get $record) (i32.const 5))
		(global.set $element-count (i32.add (global.get $element-count) (i32.const 1)))
		(local.get $record)
	)

	;; Parse a named or anonymous active, passive or declarative element segment.
	(func $parse-element
		(local $record i32)
		(local $value i32)
		(local $length i32)
		(local $open i32)

		(local.set $record (call $new-element))
		;; Failed allocation cannot write through a null descriptor.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(call $next)
		;; Duplicate names are errors within the element namespace only.
		(if (call $named)
			(then
				(local.set $value (global.get $tok))
				(local.set $length (global.get $len))
				;; Check only earlier descriptors, temporarily excluding this unnamed descriptor.
				(if (call $element-name-exists (local.get $value) (local.get $length))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(i32.store offset=32 (local.get $record) (local.get $value))
				(i32.store offset=36 (local.get $record) (local.get $length))
				(call $next)
			)
		)
		;; Declare segments establish function references but have no live runtime entries.
		(if (call $is-word (i32.const 3908) (i32.const 7))
			(then
				(i32.store offset=40 (local.get $record) (i32.const 2))
				(call $next)
			)
			;; Active segments start with a target/offset; bare lists are passive.
			(else
				;; Legacy numeric table targets and parenthesized offsets share the active path.
				(if
					(i32.or
						(i32.eq (global.get $kind) (i32.const 1))
						(i32.and
							(i32.eq (global.get $kind) (i32.const 3))
							(i32.le_u (i32.sub (i32.load8_u (global.get $tok)) (i32.const 48)) (i32.const 9))
						)
					)
					(then
						;; A table wrapper precedes the offset; other openings belong to the offset itself.
						(if (i32.eq (global.get $kind) (i32.const 1))
							(then
								(local.set $open (global.get $tok))
								(call $next)
								;; Only consume an explicit table selector, replaying initializer groups unchanged.
								(if (call $is-word (i32.const 3840) (i32.const 5))
									(then
										(call $next)
										;; An explicit selector requires its index or name before the wrapper close.
										(if (i32.ne (global.get $kind) (i32.const 3))
											(then
												(call $fail (i32.const 1))
											)
										)
										(call $segment-target (local.get $record))
										(call $expect (i32.const 2))
									)
									;; Restore the offset opening for the common constant-expression parser.
									(else
										(global.set $pos (local.get $open))
										(call $next)
									)
								)
							)
						)
						(call $segment-target (local.get $record))
						(i32.store (local.get $record) (call $initializer))
						(i32.store offset=28 (local.get $record) (global.get $initializer-reference))
					)
					;; Passive lists need no table declaration or instantiation bounds.
					(else
						(i32.store offset=40 (local.get $record) (i32.const 1))
					)
				)
			)
		)
		(call $element-functions (local.get $record))
	)

	;; Check whether a source-backed segment name was already declared.
	(func $element-name-exists
		(param $value i32)
		(param $length i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Stop after searching existing descriptor names.
		(block $done
			;; Full byte comparison preserves namespace independence and case sensitivity.
			(loop $names
				(br_if $done (i32.eq (local.get $i) (global.get $element-count)))
				(local.set $record (call $element-record (local.get $i)))
				;; An unnamed descriptor never matches a nonempty identifier.
				(if
					(i32.and
						(i32.eq (local.get $length) (i32.load offset=36 (local.get $record)))
						(call $equal
							(local.get $value)
							(i32.load offset=32 (local.get $record))
							(local.get $length)
						)
					)
					(then
						(return (i32.const 1))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(i32.const 0)
	)

	;; Parse the sole funcref table, including the inline-element abbreviation and optional exports.
	(func $parse-table
		(local $record i32)
		(local $offset i32)
		(local $index i32)
		(local $descriptor i32)

		;; A second table remains outside the supported single-table subset.
		(if (i32.ge_u (global.get $guest-table-present) (i32.const 32))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $offset (global.get $tok))
		(local.set $index (global.get $guest-table-present))
		(local.set $descriptor (call $guest-table-record (local.get $index)))
		(call $zero-bytes (local.get $descriptor) (i32.const 64))
		(call $use-table (local.get $index))
		(global.set $guest-table-present (i32.add (local.get $index) (i32.const 1)))
		(call $next)
		;; A table identifier has its own namespace, independent of memory and functions.
		(if (call $named)
			(then
				;; Duplicate names are text resolution errors within the table namespace.
				(if (i32.ne (call $find-table (global.get $tok) (global.get $len)) (i32.const -1))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(global.set $guest-table-name (global.get $tok))
				(global.set $guest-table-name-length (global.get $len))
				(call $next)
			)
		)
		(call $resource-exports (i32.const 3) (local.get $index))
		;; Inline elements fix both minimum and maximum to the number of references.
		(if
			(i32.or
				(call $is-word (i32.const 3845) (i32.const 7))
				(call $is-word (i32.const 3893) (i32.const 9))
			)
			(then
				(global.set $guest-table-type (call $value-type))
				(call $expect (i32.const 1))
				(local.set $record (call $new-element))
				;; Preserve allocation failures before attempting to populate the segment.
				(if (global.get $error)
					(then
						(return)
					)
				)
				(i32.store offset=16 (local.get $record) (local.get $index))
				(i32.store offset=48 (local.get $record) (global.get $guest-table-type))
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
				(if
					(i32.eqz
						(i32.or
							(call $is-word (i32.const 3845) (i32.const 7))
							(call $is-word (i32.const 3893) (i32.const 9))
						)
					)
					(then
						(global.set $guest-table-max (call $index))
					)
				)
				(global.set $guest-table-type (call $value-type))
				;; A table requires one of the two reference value types.
				(if (i32.lt_u (global.get $guest-table-type) (i32.const 5))
					(then
						(call $fail (i32.const 7))
					)
				)
			)
		)
		(i32.store (local.get $descriptor) (global.get $guest-table-name))
		(i32.store offset=4 (local.get $descriptor) (global.get $guest-table-name-length))
		(i32.store offset=8 (local.get $descriptor) (global.get $guest-table-size))
		(i32.store offset=12 (local.get $descriptor) (global.get $guest-table-max))
		(i32.store offset=16 (local.get $descriptor) (global.get $guest-table-type))
		(call $expect (i32.const 2))
		(call $finish-resource-declaration (i32.const 3) (local.get $index))
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

	;; Resolve segment targets and declare every referenced function before validating bodies.
	(func $resolve-elements
		(local $i i32)
		(local $entry i32)
		(local $record i32)

		;; All modes validate their entries, including declarative segments without a table.
		(block $done
			;; Only active segments require the sole funcref table and compatible element type.
			(loop $segments
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $element-count)))
				(local.set $record (call $element-record (local.get $i)))
				;; Passive/declarative segments are independent of the table namespace.
				(if (i32.eqz (i32.load offset=40 (local.get $record)))
					(then
						(i32.store offset=16
							(local.get $record)
							(call $resource-target
								(i32.const 3)
								(i32.load offset=16 (local.get $record))
								(i32.load offset=20 (local.get $record))
								(i32.load offset=12 (local.get $record))
							)
						)
						(i32.store offset=20 (local.get $record) (i32.const 0))
						(call $use-table (i32.load offset=16 (local.get $record)))
						;; Element and target table types must agree exactly.
						(if (i32.ne (i32.load offset=48 (local.get $record)) (global.get $guest-table-type))
							(then
								(call $fail (i32.const 7))
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $segments)
			)
		)
		(local.set $i (i32.const 0))
		;; Finish after every entry has a valid function target or a typed constant expression.
		(block $done
			;; Null and global entries were type-checked during parsing and do not declare a function.
			(loop $entries
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $element-entry-count)))
				(local.set $entry
					(i32.add (global.get $element-entry-base) (i32.mul (local.get $i) (i32.const 16)))
				)
				;; Legacy and expression function references resolve identically.
				(if (i32.eqz (i32.load offset=12 (local.get $entry)))
					(then
						(i32.store
							(local.get $entry)
							(call $target
								(i32.load (local.get $entry))
								(i32.load offset=4 (local.get $entry))
								(i32.load offset=8 (local.get $entry))
							)
						)
						(call $declare-function (i32.load (local.get $entry)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Return the current table-storage representation of a validated element constant.
	(func $element-value
		(param $entry i32)
		(result i32)

		;; Imported immutable globals are read after resource binding and converted from nullable slots.
		(if (i32.eq (i32.load offset=12 (local.get $entry)) (i32.const 49))
			(then
				(return
					(i32.sub
						(i32.wrap_i64 (i64.load offset=24 (call $global-record (i32.load (local.get $entry)))))
						(i32.const 1)
					)
				)
			)
		)
		(i32.load (local.get $entry))
	)

	;; Initialize table entries to null, then apply active segments in source order with unsigned bounds checks.
	(func $allocate-table
		(local $i i32)
		(local $table i32)
		(local $j i32)
		(local $record i32)
		(local $start i32)
		(local $count i32)

		;; Visit every independent table arena before applying any active segment.
		(block $all-done
			;; Initial allocation null-fills each declared table independently.
			(loop $tables
				(br_if $all-done (i32.eq (local.get $table) (global.get $guest-table-present)))
				(call $use-table (local.get $table))
				(local.set $i (i32.const 0))
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
				(local.set $table (i32.add (local.get $table) (i32.const 1)))
				(br $tables)
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
				(local.set $record (call $element-record (local.get $i)))
				;; Passive and declarative descriptors never initialize table entries.
				(if (i32.load offset=40 (local.get $record))
					(then
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $segments)
					)
				)
				(drop
					(call $resource-target
						(i32.const 3)
						(i32.load offset=16 (local.get $record))
						(i32.load offset=20 (local.get $record))
						(i32.load offset=24 (local.get $record))
					)
				)
				(call $use-table (i32.load offset=16 (local.get $record)))
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
							(call $element-value
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

	;; Read one optional table index or name into a deferred reference pair.
	(func $table-reference
		(param $record i32)
		(result i32)

		;; Names preserve their source span until all module fields are available.
		(if (call $named)
			(then
				(i32.store (local.get $record) (global.get $tok))
				(i32.store offset=4 (local.get $record) (global.get $len))
				(call $next)
				(return (i32.const 1))
			)
		)
		;; Only digit-led atoms are numeric indices; instruction atoms start the next operation.
		(if
			(i32.and
				(i32.eq (global.get $kind) (i32.const 3))
				(i32.and
					(i32.ge_u (i32.load8_u (global.get $tok)) (i32.const 48))
					(i32.le_u (i32.load8_u (global.get $tok)) (i32.const 57))
				)
			)
			(then
				(i32.store (local.get $record) (call $index))
				(return (i32.const 1))
			)
		)
		(i32.const 0)
	)

	;; Save one size target or a copy target pair in the bounded auxiliary immediate arena.
	(func $table-immediate
		(param $op i32)
		(result i32)
		(local $record i32)

		(local.set $record
			(i32.add (global.get $table-base) (i32.mul (global.get $table-count) (i32.const 4)))
		)
		;; Four slots retain both index/name pairs without overlapping later branch vectors.
		(if
			(i32.gt_u (global.get $table-count) (i32.sub (i32.const CAP_TABLE) (i32.const 4)))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(global.set $table-count (i32.add (global.get $table-count) (i32.const 4)))
		(i64.store (local.get $record) (i64.const 0))
		(i64.store offset=8 (local.get $record) (i64.const 0))
		;; Omitting indices selects table zero; copy explicitly names both targets together.
		(if (call $table-reference (local.get $record))
			(then
				;; A copy's explicit destination requires an explicit source, including in folded syntax.
				(if (i32.eq (local.get $op) (i32.const 192))
					(then
						;; Reject an incomplete index pair before consuming folded operand expressions.
						(if (i32.eqz (call $table-reference (i32.add (local.get $record) (i32.const 8))))
							(then
								(call $fail (i32.const 1))
							)
						)
					)
				)
			)
		)
		(local.get $record)
	)

	;; Check both table ranges with unsigned arithmetic before moving any function reference.
	(func $table-copy
		(param $source-table i32)
		(param $destination i32)
		(param $source i32)
		(param $length i32)
		(local $i i32)
		(local $slot i32)
		(local $source-base i32)

		(local.set $source-base
			(i32.add (call $canonical-table-record (local.get $source-table)) (i32.const 64))
		)
		;; Each endpoint may equal the size only when its complete range is empty.
		(if
			(i32.or
				(i64.gt_u
					(i64.add
						(i64.extend_i32_u (local.get $destination))
						(i64.extend_i32_u (local.get $length))
					)
					(i64.extend_i32_u (global.get $guest-table-size))
				)
				(i64.gt_u
					(i64.add (i64.extend_i32_u (local.get $source)) (i64.extend_i32_u (local.get $length)))
					(i64.extend_i32_u
						(i32.load offset=8 (call $canonical-table-record (local.get $source-table)))
					)
				)
			)
			(then
				(call $fail (i32.const 30))
				(return)
			)
		)
		;; Stop after all references have moved, preserving null slots as well as callable entries.
		(block $done
			;; Moving backward for a later destination preserves overlapping source entries.
			(loop $entries
				(br_if $done (i32.eq (local.get $i) (local.get $length)))
				(local.set $slot
					(select
						(i32.sub (i32.sub (local.get $length) (local.get $i)) (i32.const 1))
						(local.get $i)
						(i32.gt_u (local.get $destination) (local.get $source))
					)
				)
				(i32.store
					(i32.add
						(global.get $guest-table-base)
						(i32.mul (i32.add (local.get $destination) (local.get $slot)) (i32.const 4))
					)
					(i32.load
						(i32.add
							(local.get $source-base)
							(i32.mul (i32.add (local.get $source) (local.get $slot)) (i32.const 4))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Parse the required element target and optional leading table target for table.init.
	(func $element-immediate
		(result i32)
		(local $record i32)

		;; table.init always requires a segment index, unlike optional table.size targets.
		(if
			(i32.eqz
				(i32.or
					(call $named)
					(i32.and
						(i32.eq (global.get $kind) (i32.const 3))
						(i32.le_u (i32.sub (i32.load8_u (global.get $tok)) (i32.const 48)) (i32.const 9))
					)
				)
			)
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(local.set $record (call $table-immediate (i32.const 197)))
		;; A single index names the element segment and leaves the table target at zero.
		(if (i32.eqz (call $table-reference (i32.add (local.get $record) (i32.const 8))))
			(then
				(i64.store offset=8 (local.get $record) (i64.load (local.get $record)))
				(i64.store (local.get $record) (i64.const 0))
			)
		)
		(local.get $record)
	)

	;; Copy a checked source segment range into a checked destination table range without consuming it.
	(func $element-init
		(param $index i32)
		(param $destination i32)
		(param $source i32)
		(param $length i32)
		(local $record i32)
		(local $i i32)
		(local $entry i32)

		(local.set $record (call $element-record (local.get $index)))
		;; Complete unsigned ranges must fit before publishing the first table write.
		(if
			(i32.or
				(i64.gt_u
					(i64.add
						(i64.extend_i32_u (local.get $destination))
						(i64.extend_i32_u (local.get $length))
					)
					(i64.extend_i32_u (global.get $guest-table-size))
				)
				(i64.gt_u
					(i64.add (i64.extend_i32_u (local.get $source)) (i64.extend_i32_u (local.get $length)))
					(i64.extend_i32_u (i32.load offset=44 (local.get $record)))
				)
			)
			(then
				(call $fail (i32.const 30))
				(return)
			)
		)
		;; Empty ranges perform no accesses, including after active/declarative segments have been dropped.
		(block $done
			;; Element and table storage are separate, so source entries cannot overlap table writes.
			(loop $entries
				(br_if $done (i32.eq (local.get $i) (local.get $length)))
				(local.set $entry
					(i32.add
						(global.get $element-entry-base)
						(i32.mul
							(i32.add
								(i32.load offset=4 (local.get $record))
								(i32.add (local.get $source) (local.get $i))
							)
							(i32.const 16)
						)
					)
				)
				(i32.store
					(i32.add
						(global.get $guest-table-base)
						(i32.mul (i32.add (local.get $destination) (local.get $i)) (i32.const 4))
					)
					(call $element-value (local.get $entry))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Read or replace one table entry using nullable function-reference value slots.
	(func $table-access
		(param $op i32)
		(param $index i32)
		(param $value i64)
		(result i64)
		(local $address i32)

		;; Unsigned indices must identify a present entry, even when writing a null value.
		(if (i32.ge_u (local.get $index) (global.get $guest-table-size))
			(then
				(call $fail (i32.const 30))
				(return (i64.const 0))
			)
		)
		(local.set $address
			(i32.add (global.get $guest-table-base) (i32.mul (local.get $index) (i32.const 4)))
		)
		;; get converts storage's -1 null sentinel into the reference slot's zero null.
		(if (i32.eq (local.get $op) (i32.const 198))
			(then
				(return (i64.extend_i32_u (i32.add (i32.load (local.get $address)) (i32.const 1))))
			)
		)
		(i32.store (local.get $address) (i32.sub (i32.wrap_i64 (local.get $value)) (i32.const 1)))
		(i64.const 0)
	)

	;; Fill a complete checked range with one nullable function reference.
	(func $table-fill
		(param $start i32)
		(param $value i64)
		(param $length i32)
		(local $i i32)

		;; Validate the whole unsigned range before changing any entry.
		(if
			(i64.gt_u
				(i64.add (i64.extend_i32_u (local.get $start)) (i64.extend_i32_u (local.get $length)))
				(i64.extend_i32_u (global.get $guest-table-size))
			)
			(then
				(call $fail (i32.const 30))
				(return)
			)
		)
		;; Empty ranges perform no access, including at the logical end.
		(block $done
			;; Write scalar entries so interpreted execution uses the same implementation.
			(loop $entries
				(br_if $done (i32.eq (local.get $i) (local.get $length)))
				(i32.store
					(i32.add
						(global.get $guest-table-base)
						(i32.mul (i32.add (local.get $start) (local.get $i)) (i32.const 4))
					)
					(i32.sub (i32.wrap_i64 (local.get $value)) (i32.const 1))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $entries)
			)
		)
	)

	;; Grow within declared and storage limits, returning the old size or -1 without mutation.
	(func $table-grow
		(param $value i64)
		(param $delta i32)
		(result i32)
		(local $old i32)
		(local $size i64)

		(local.set $old (global.get $guest-table-size))
		(local.set $size
			(i64.add (i64.extend_i32_u (local.get $old)) (i64.extend_i32_u (local.get $delta)))
		)
		;; Allocation failure is a result, rather than a table bounds trap.
		(if
			(i32.or
				(i64.gt_u (local.get $size) (i64.extend_i32_u (global.get $guest-table-max)))
				(i64.gt_u (local.get $size) (i64.const 4096))
			)
			(then
				(return (i32.const -1))
			)
		)
		(global.set $guest-table-size (i32.wrap_i64 (local.get $size)))
		(i32.store offset=8
			(call $guest-table-record (global.get $guest-table-index))
			(global.get $guest-table-size)
		)
		(call $table-fill (local.get $old) (local.get $value) (local.get $delta))
		(local.get $old)
	)
