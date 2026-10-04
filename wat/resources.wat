	;; Decode a string name into stable bytes and validate its complete UTF-8 encoding.
	(func $export-name
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $tok i32)
		(local $len i32)
		(local $pos i32)
		(local $kind i32)
		(local $start i32)
		(local $end i32)
		(local $cursor i32)

		(local.set $tok (global.get $tok))
		(local.set $len (global.get $len))
		(local.set $pos (global.get $pos))
		(local.set $kind (global.get $kind))
		(local.set $start (i32.add (global.get $data-base) (global.get $data-count)))
		(global.set $tok (local.get $p))
		(global.set $len (local.get $n))
		(call $decode-data)
		(local.set $end (i32.add (global.get $data-base) (global.get $data-count)))
		(local.set $cursor (local.get $start))
		;; Byte escapes can introduce invalid encodings, so validate after decoding as well.
		(block $done
			;; Each iteration consumes one complete Unicode scalar, including embedded NUL.
			(loop $scalars
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $cursor) (local.get $end)))
				(local.set $cursor
					(i32.add (local.get $cursor) (call $utf8-length (local.get $cursor) (local.get $end)))
				)
				(br $scalars)
			)
		)
		(global.set $decoded-name-length (i32.sub (local.get $end) (local.get $start)))
		(global.set $tok (local.get $tok))
		(global.set $len (local.get $len))
		(global.set $pos (local.get $pos))
		(global.set $kind (local.get $kind))
		(local.get $start)
	)

	;; Decode an export descriptor keyword into function=0, memory=1, global=2 or table=3.
	(func $export-kind
		(result i32)

		;; Function descriptors retain the existing export behavior.
		(if (call $is-word (i32.const 6) (i32.const 4))
			(then
				(return (i32.const 0))
			)
		)
		;; Memory descriptors name the sole MVP guest memory.
		(if (call $is-word (i32.const 80) (i32.const 6))
			(then
				(return (i32.const 1))
			)
		)
		;; Global descriptors address the independent global namespace.
		(if (call $is-word (i32.const 86) (i32.const 6))
			(then
				(return (i32.const 2))
			)
		)
		;; Table exports address the sole function table and retain their distinct kind.
		(if (call $is-word (i32.const 3840) (i32.const 5))
			(then
				(return (i32.const 3))
			)
		)
		(call $fail (i32.const 2))
		(i32.const 0)
	)

	;; Locate a global record: identifier at 0/4, mutability/type at 8/12, initial/current i64 values at 16/24.
	(func $global-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $global-base) (i32.mul (local.get $index) (i32.const 80)))
	)

	;; Find a named global independently from function and local names; return -1 when absent.
	(func $find-global
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Missing names fall through after the last global record.
		(block $missing
			;; Compare complete identifier spans in source order.
			(loop $search
				(br_if $missing (i32.eq (local.get $i) (global.get $global-count)))
				(local.set $record (call $global-record (local.get $i)))
				;; Length and bytes must both match a named declaration.
				(if
					(i32.and
						(i32.eq (local.get $n) (i32.load offset=4 (local.get $record)))
						(call $equal (local.get $p) (i32.load (local.get $record)) (local.get $n))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $search)
			)
		)
		(i32.const -1)
	)

	;; Resolve a typed export/global reference and reject missing or out-of-range targets.
	(func $resource-target
		(param $category i32)
		(param $value i32)
		(param $length i32)
		(param $offset i32)
		(result i32)
		(local $count i32)

		;; Functions continue to use their established resolver.
		(if (i32.eqz (local.get $category))
			(then
				(return (call $target (local.get $value) (local.get $length) (local.get $offset)))
			)
		)
		;; Table names and indices resolve independently from memory and global namespaces.
		(if (i32.eq (local.get $category) (i32.const 3))
			(then
				;; Names resolve across the complete table namespace.
				(if (local.get $length)
					(then
						(local.set $value (call $find-table (local.get $value) (local.get $length)))
					)
				)
				;; Missing tables and out-of-range targets are validation reference errors.
				(if (i32.ge_u (local.get $value) (global.get $guest-table-present))
					(then
						(global.set $tok (local.get $offset))
						(call $fail (i32.const 10))
					)
				)
				(return (local.get $value))
			)
		)
		;; Memory has one possible numeric index and an optional source-backed name.
		(if (i32.eq (local.get $category) (i32.const 1))
			(then
				(local.set $count (global.get $memory-present))
				;; Resolve the sole memory name without reusing another namespace.
				(if (local.get $length)
					(then
						(local.set $value
							(select
								(i32.const 0)
								(i32.const -1)
								(i32.and
									(i32.eq (local.get $length) (global.get $memory-name-length))
									(call $equal (local.get $value) (global.get $memory-name) (local.get $length))
								)
							)
						)
					)
				)
			)
			;; Global references may be forward names or source-order indices.
			(else
				(local.set $count (global.get $global-count))
				;; Resolve names only after all globals have been declared.
				(if (local.get $length)
					(then
						(local.set $value (call $find-global (local.get $value) (local.get $length)))
					)
				)
			)
		)
		;; Unknown names and invalid indices share the reference diagnostic.
		(if (i32.ge_u (local.get $value) (local.get $count))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const 10))
			)
		)
		(local.get $value)
	)

	;; Consume inline resource exports, replaying any opening parenthesis belonging to the type.
	(func $resource-exports
		(param $category i32)
		(param $index i32)
		(local $open i32)
		(local $p i32)
		(local $n i32)

		;; Finish before the resource type, limits or initializer.
		(block $done
			;; Multiple inline exports all point to the same resource index.
			(loop $exports
				(br_if $done (global.get $error))
				(br_if $done (i32.ne (global.get $kind) (i32.const 1)))
				(local.set $open (global.get $tok))
				(call $next)
				;; Inline import annotations use the same descriptor as module-level imports.
				(if (call $is-word (i32.const 112) (i32.const 6))
					(then
						;; A resource cannot carry two import annotations.
						(if (global.get $parsing-import)
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $read-import-names (local.get $index))
						(call $expect (i32.const 2))
						(global.set $parsing-import (i32.const 1))
						(br $exports)
					)
				)
				;; A non-export opening belongs to the following type/initializer grammar.
				(if (i32.eqz (call $is-word (i32.const 11) (i32.const 6)))
					(then
						(global.set $pos (local.get $open))
						(call $next)
						(br $done)
					)
				)
				(call $next)
				(local.set $p (global.get $tok))
				(local.set $n (global.get $len))
				(call $expect (i32.const 4))
				(call $expect (i32.const 2))
				(call $add-export
					(local.get $p)
					(local.get $n)
					(local.get $index)
					(i32.const 0)
					(local.get $open)
					(local.get $category)
				)
				(br $exports)
			)
		)
	)

	;; Parse the single MVP memory, its optional identifier/exports and unsigned page limits.
	(func $parse-memory
		(local $bytes i32)

		;; Multiple memories require an extension outside the current MVP subset.
		(if (global.get $memory-present)
			(then
				(call $fail (i32.const 2))
				(return)
			)
		)
		(global.set $memory-offset (global.get $tok))
		(global.set $memory-present (i32.const 1))
		(call $next)
		;; A memory identifier is optional and participates only in memory exports.
		(if (call $named)
			(then
				(global.set $memory-name (global.get $tok))
				(global.set $memory-name-length (global.get $len))
				(call $next)
			)
		)
		(call $resource-exports (i32.const 1) (i32.const 0))
		;; The inline data abbreviation declares a fixed-size memory and an active segment at offset zero.
		(if (i32.eq (global.get $kind) (i32.const 1))
			(then
				(call $expect (i32.const 1))
				(call $word (i32.const 92) (i32.const 4))
				(local.set $bytes (call $data-segment (i32.const 0) (global.get $memory-offset)))
				(global.set $guest-min
					(i32.div_u (i32.add (local.get $bytes) (i32.const 65535)) (i32.const 65536))
				)
				(global.set $guest-max (global.get $guest-min))
				(call $expect (i32.const 2))
				(return)
			)
		)
		(global.set $guest-min (call $index))
		(global.set $guest-max (i32.const 65536))
		;; A second unsigned limit supplies the declared maximum page count.
		(if (i32.ne (global.get $kind) (i32.const 2))
			(then
				(global.set $memory-max-present (i32.const 1))
				(global.set $guest-max (call $index))
			)
		)
		(call $expect (i32.const 2))
		(call $finish-resource-declaration (i32.const 1) (i32.const 0))
		;; MVP memory limits cannot exceed 65536 pages or put the maximum below the minimum.
		(if
			(i32.or
				(i32.gt_u (global.get $guest-max) (i32.const 65536))
				(i32.gt_u (global.get $guest-min) (global.get $guest-max))
			)
			(then
				(global.set $tok (global.get $memory-offset))
				(call $fail (i32.const 15))
			)
		)
	)

	;; Read an optional memory/table target into a segment descriptor for deferred namespace resolution.
	(func $segment-target
		(param $record i32)

		(i32.store offset=24 (local.get $record) (global.get $tok))
		;; Omitting the index selects resource zero, while atoms spell a numeric index or name.
		(if (i32.eq (global.get $kind) (i32.const 3))
			(then
				;; Named resources can be defined after the segment.
				(if (call $named)
					(then
						(i32.store offset=16 (local.get $record) (global.get $tok))
						(i32.store offset=20 (local.get $record) (global.get $len))
						(call $next)
					)
					;; Numeric targets are checked against the completed resource namespace.
					(else
						(i32.store offset=16 (local.get $record) (call $index))
					)
				)
			)
		)
	)

	;; Parse an i32 constant offset, optionally enclosed in the explicit offset abbreviation.
	(func $initializer
		(result i32)
		(local $value i32)
		(local $wrapped i32)

		(global.set $initializer-reference (i32.const 0))
		(call $expect (i32.const 1))
		;; An offset wrapper contains exactly one constant expression.
		(if (call $is-word (i32.const 99) (i32.const 6))
			(then
				(local.set $wrapped (i32.const 1))
				(call $next)
				(call $expect (i32.const 1))
			)
		)
		;; Offsets may read an imported immutable i32 global or contain an i32 literal.
		(if (i32.eq (call $opcode) (i32.const 49))
			(then
				(call $read-initializer-global (i32.const 1))
			)
			;; Other expressions must be the MVP i32.const form.
			(else
				(call $word (i32.const 26) (i32.const 9))
				(local.set $value (call $integer))
			)
		)
		(call $expect (i32.const 2))
		;; Close the wrapper after its single expression, if one was present.
		(if (local.get $wrapped)
			(then
				(call $expect (i32.const 2))
			)
		)
		(local.get $value)
	)

	;; Parse an immutable or mutable integer global with a literal initializer and optional exports.
	(func $parse-global
		(local $p i32)
		(local $n i32)
		(local $record i32)
		(local $mutable i32)
		(local $value i64)
		(local $type i32)
		(local $offset i32)

		(local.set $offset (global.get $tok))
		(call $next)
		;; Global capacity protects its fixed record arena.
		(if (i32.ge_u (global.get $global-count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		;; Named globals must be unique within their own namespace.
		(if (call $named)
			(then
				(local.set $p (global.get $tok))
				(local.set $n (global.get $len))
				;; Functions and locals may share this identifier, but another global may not.
				(if (i32.ne (call $find-global (local.get $p) (local.get $n)) (i32.const -1))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(call $next)
			)
		)
		(call $resource-exports (i32.const 2) (global.get $global-count))
		;; Parenthesized mut wraps the global's supported value type.
		(if (i32.eq (global.get $kind) (i32.const 1))
			(then
				(call $next)
				(call $word (i32.const 96) (i32.const 3))
				(local.set $type (call $value-type))
				(call $expect (i32.const 2))
				(local.set $mutable (i32.const 1))
			)
			;; A bare integer type declares an immutable global.
			(else
				(local.set $type (call $value-type))
			)
		)
		(global.set $initializer-reference (i32.const 0))
		(global.set $initializer-function-present (i32.const 0))
		(global.set $initializer-high (i64.const 0))
		;; Imported globals have no initializer; their values are supplied through their link descriptor.
		(if (i32.eqz (global.get $parsing-import))
			(then
				(local.set $value (call $global-initializer (local.get $type)))
			)
		)
		(call $expect (i32.const 2))
		(local.set $record (call $global-record (global.get $global-count)))
		(i32.store (local.get $record) (local.get $p))
		(i32.store offset=4 (local.get $record) (local.get $n))
		(i32.store offset=8 (local.get $record) (local.get $mutable))
		(i32.store offset=12 (local.get $record) (local.get $type))
		(i64.store offset=16 (local.get $record) (local.get $value))
		(i64.store offset=24 (local.get $record) (local.get $value))
		(i64.store offset=64 (local.get $record) (global.get $initializer-high))
		(i64.store offset=72 (local.get $record) (global.get $initializer-high))
		(i32.store offset=40 (local.get $record) (global.get $initializer-reference))
		(i32.store offset=44 (local.get $record) (global.get $initializer-function))
		(i32.store offset=48 (local.get $record) (global.get $initializer-function-length))
		(i32.store offset=52 (local.get $record) (global.get $initializer-function-source))
		(i32.store offset=56 (local.get $record) (global.get $initializer-function-present))
		(i32.store offset=36 (local.get $record) (global.get $parsing-import))
		(call $finish-resource-declaration (i32.const 2) (global.get $global-count))
		(i32.store offset=32 (local.get $record) (local.get $offset))
		(global.set $global-count (i32.add (global.get $global-count) (i32.const 1)))
	)

	;; Allocate a fresh logical memory, clear it, check every segment, then apply segments in source order.
	(func $allocate-resources
		(local $base i64)
		(local $end i64)
		(local $i i32)
		(local $record i32)
		(local $address i32)
		(local $j i32)
		(local $length i32)

		(local.set $base
			(i64.and
				(i64.add (i64.extend_i32_u (global.get $host-base)) (i64.const 65535))
				(i64.const -65536)
			)
		)
		;; The initial memory size must fit the current implementation capacity.
		(if
			(i32.and
				(global.get $memory-present)
				(i32.gt_u (global.get $guest-min) (i32.const CAP_PAGES))
			)
			(then
				(global.set $tok (global.get $memory-offset))
				(call $fail (i32.const 6))
				(return)
			)
		)
		;; An absent memory must not inherit minimum pages from a previous module.
		(if (global.get $memory-present)
			(then
				(global.set $guest-pages (global.get $guest-min))
			)
		)
		(local.set $end
			(i64.add
				(local.get $base)
				(i64.mul (i64.extend_i32_u (global.get $guest-pages)) (i64.const 65536))
			)
		)
		;; Reserve scratch space even for modules without a memory or with zero pages.
		(if (i32.eqz (call $ensure-bytes (i64.add (local.get $end) (i64.const 1024))))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(global.set $guest-base (i32.wrap_i64 (local.get $base)))
		(global.set $host-base (i32.wrap_i64 (local.get $end)))
		(call $zero-bytes
			(global.get $guest-base)
			(i32.mul (global.get $guest-pages) (i32.const 65536))
		)
	)

	;; Apply active data segments after linked memory contents and globals are available.
	(func $apply-data
		(local $i i32)
		(local $record i32)
		(local $address i32)
		(local $j i32)
		(local $length i32)

		;; Complete segment initialization after all source-order records have been processed.
		(block $done
			;; Empty segments still require a memory and an in-bounds offset.
			(loop $segments
				(br_if $done (i32.eq (local.get $i) (global.get $segment-count)))
				(local.set $record
					(i32.add (global.get $segment-base) (i32.mul (local.get $i) (i32.const 48)))
				)
				;; Passive data remains available to memory.init and performs no instantiation writes.
				(if (i32.load offset=40 (local.get $record))
					(then
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $segments)
					)
				)
				(drop
					(call $resource-target
						(i32.const 1)
						(i32.load offset=16 (local.get $record))
						(i32.load offset=20 (local.get $record))
						(i32.load offset=24 (local.get $record))
					)
				)
				;; Invalid target indices must fail validation even for empty segments.
				(if (global.get $error)
					(then
						(return)
					)
				)
				(global.set $tok (i32.load offset=12 (local.get $record)))
				;; Active segments cannot target an absent default memory.
				(if (i32.eqz (global.get $memory-present))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(local.set $length (i32.load offset=8 (local.get $record)))
				;; Imported-global offsets use the linked value rather than the parse-time placeholder.
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
				(local.set $address
					(call $guest-address (i32.load (local.get $record)) (i32.const 0) (local.get $length))
				)
				;; A failed initializer invalidates the module before it can be invoked.
				(if (global.get $error)
					(then
						(return)
					)
				)
				(local.set $j (i32.const 0))
				;; Finish copying this segment at its decoded length.
				(block $copied
					;; Later overlapping segments overwrite bytes written by earlier segments.
					(loop $copy
						(br_if $copied (i32.eq (local.get $j) (local.get $length)))
						(i32.store8
							(i32.add (local.get $address) (local.get $j))
							(i32.load8_u
								(i32.add
									(global.get $data-base)
									(i32.add (i32.load offset=4 (local.get $record)) (local.get $j))
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

	;; Look up a typed host export after checking readiness and the name buffer; zero signals failure.
	(func $host-export
		(param $p i32)
		(param $n i32)
		(param $category i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		(global.set $error (i32.const 0))
		(global.set $tok (local.get $p))
		;; Host resource access requires a successfully loaded module.
		(if (i32.eqz (global.get $ready))
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		;; Compare source names only after verifying the host input range.
		(if (i32.eqz (call $buffer-ok (local.get $p) (local.get $n)))
			(then
				(call $fail (i32.const 5))
				(return (i32.const 0))
			)
		)
		;; Missing names fall through to the unknown-export diagnostic.
		(block $missing
			;; All resource kinds share the same unique export-name namespace.
			(loop $exports
				(br_if $missing (i32.eq (local.get $i) (global.get $export-count)))
				(local.set $record
					(i32.add (global.get $export-base) (i32.mul (local.get $i) (i32.const 32)))
				)
				;; Select only an exact byte-for-byte name match.
				(if
					(i32.and
						(i32.eq (local.get $n) (i32.load offset=4 (local.get $record)))
						(call $equal (local.get $p) (i32.load (local.get $record)) (local.get $n))
					)
					(then
						;; A matching name must refer to the resource kind requested by this host operation.
						(if (i32.ne (i32.load offset=20 (local.get $record)) (local.get $category))
							(then
								(call $fail (i32.const 18))
								(return (i32.const 0))
							)
						)
						(return (local.get $record))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $exports)
			)
		)
		(call $fail (i32.const 4))
		(i32.const 0)
	)

	;; Query an exported global's scalar type so the host selects Number or BigInt.
	(func $global-type (export "global_type")
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 2)))
		;; Failed lookups cannot dereference a global record.
		(if (global.get $error)
			(then
				(return (i32.const 0))
			)
		)
		(i32.load offset=12 (call $global-record (i32.load offset=8 (local.get $record))))
	)

	;; Read an exported global as a wide slot; its declared type determines the host representation.
	(func $get-global64 (export "get_global64")
		(param $p i32)
		(param $n i32)
		(result i64)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 2)))
		;; Preserve lookup errors without accessing another arena.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		(i64.load offset=24 (call $global-record (i32.load offset=8 (local.get $record))))
	)

	;; Preserve the old i32-only global getter while rejecting wide globals.
	(func (export "get_global")
		(param $p i32)
		(param $n i32)
		(result i32)

		;; A narrow API cannot silently truncate an exported i64 global.
		(if (i32.ne (call $global-type (local.get $p) (local.get $n)) (i32.const 1))
			(then
				(call $fail (i32.const 23))
				(return (i32.const 0))
			)
		)
		(i32.wrap_i64 (call $get-global64 (local.get $p) (local.get $n)))
	)

	;; Write an exported mutable global, canonicalizing i32 values within the wide slot.
	(func $set-global64 (export "set_global64")
		(param $p i32)
		(param $n i32)
		(param $value i64)
		(result i32)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 2)))
		;; Stop before dereferencing a failed lookup.
		(if (global.get $error)
			(then
				(return (global.get $error))
			)
		)
		(local.set $record (call $global-record (i32.load offset=8 (local.get $record))))
		;; Immutable globals reject host writes independently of their width.
		(if (i32.eqz (i32.load offset=8 (local.get $record)))
			(then
				(call $fail (i32.const 16))
				(return (global.get $error))
			)
		)
		(local.set $value
			(call $canonical-value (local.get $value) (i32.load offset=12 (local.get $record)))
		)
		(i64.store offset=24 (local.get $record) (local.get $value))
		(i32.const 0)
	)

	;; Preserve the old i32-only global setter without accepting an i64 target.
	(func (export "set_global")
		(param $p i32)
		(param $n i32)
		(param $value i32)
		(result i32)

		;; Invalid names preserve their original diagnostic; valid wide globals fail the type check.
		(if (i32.ne (call $global-type (local.get $p) (local.get $n)) (i32.const 1))
			(then
				(call $fail (i32.const 23))
				(return (global.get $error))
			)
		)
		(call $set-global64 (local.get $p) (local.get $n) (i64.extend_i32_s (local.get $value)))
	)

	;; Allocate standalone memory and apply its segments as one load-time operation.
	(func $instantiate-resources
		(call $allocate-resources)
		;; Allocation failure must not allow segment writes.
		(if (i32.eqz (global.get $error))
			(then
				(call $apply-data)
			)
		)
	)

	;; Evaluate defined global initializers after imported global values have been linked.
	(func $initialize-global-references
		(local $i i32)
		(local $record i32)

		;; Finish at the complete global namespace.
		(block $done
			;; Only definitions with deferred imported-global initializers need evaluation.
			(loop $globals
				(br_if $done (i32.eq (local.get $i) (global.get $global-count)))
				(local.set $record (call $global-record (local.get $i)))
				;; A nonzero reference stores the target index plus one.
				(if (i32.load offset=40 (local.get $record))
					(then
						(i64.store offset=72
							(local.get $record)
							(i64.load offset=72
								(call $global-record (i32.sub (i32.load offset=40 (local.get $record)) (i32.const 1)))
							)
						)
						(i64.store offset=24
							(local.get $record)
							(i64.load offset=24
								(call $global-record (i32.sub (i32.load offset=40 (local.get $record)) (i32.const 1)))
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $globals)
			)
		)
	)

	;; Read an exported vector global's high half through the trusted wide host ABI.
	(func (export "global_high")
		(param $p i32)
		(param $n i32)
		(result i64)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 2)))
		;; Failed lookups cannot read an unrelated global record.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		(i64.load offset=72 (call $global-record (i32.load offset=8 (local.get $record))))
	)

	;; Complete a validated exported vector global write with its high half.
	(func (export "set_global_high")
		(param $p i32)
		(param $n i32)
		(param $value i64)
		(result i32)
		(local $record i32)

		(local.set $record (call $host-export (local.get $p) (local.get $n) (i32.const 2)))
		;; Invalid lookups leave every protected global unchanged.
		(if (global.get $error)
			(then
				(return (global.get $error))
			)
		)
		(local.set $record (call $global-record (i32.load offset=8 (local.get $record))))
		;; Only mutable vector globals expose this additional value slot.
		(if
			(i32.or
				(i32.eqz (i32.load offset=8 (local.get $record)))
				(i32.ne (i32.load offset=12 (local.get $record)) (i32.const 7))
			)
			(then
				(return (i32.const 16))
			)
		)
		(i64.store offset=72 (local.get $record) (local.get $value))
		(i32.const 0)
	)
