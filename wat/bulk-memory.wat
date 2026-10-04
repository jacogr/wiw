	;; Execute bulk copy/fill only after all unsigned guest ranges pass bounds checks.
	(func $bulk-memory
		(param $op i32)
		(param $destination i32)
		(param $source i32)
		(param $length i32)
		(local $dest i32)
		(local $src i32)
		(local $i i32)
		(local $pattern i64)

		(local.set $dest
			(call $guest-address (local.get $destination) (i32.const 0) (local.get $length))
		)
		;; An invalid destination traps before copying or filling any byte.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Copy also validates its entire source before publishing destination writes.
		(if (i32.eq (local.get $op) (i32.const 187))
			(then
				(local.set $src
					(call $guest-address (local.get $source) (i32.const 0) (local.get $length))
				)
				;; Invalid sources leave the checked destination unchanged.
				(if (global.get $error)
					(then
						(return)
					)
				)
				;; Copy backward when a later destination overlaps unread source bytes.
				(if (i32.gt_u (local.get $destination) (local.get $source))
					(then
						(local.set $i (local.get $length))
						;; Stop once fewer than eight bytes remain at the start of the range.
						(block $slots-done
							;; Load each complete slot before overwriting any overlapping bytes.
							(loop $slots
								(br_if $slots-done (i32.lt_u (local.get $i) (i32.const 8)))
								(local.set $i (i32.sub (local.get $i) (i32.const 8)))
								(i64.store
									(i32.add (local.get $dest) (local.get $i))
									(i64.load (i32.add (local.get $src) (local.get $i)))
								)
								(br $slots)
							)
						)
						;; Complete the zero to seven leading bytes without crossing the range.
						(block $done
							;; Decreasing offsets preserve overlap even for single-byte shifts.
							(loop $bytes
								(br_if $done (i32.eqz (local.get $i)))
								(local.set $i (i32.sub (local.get $i) (i32.const 1)))
								(i32.store8
									(i32.add (local.get $dest) (local.get $i))
									(i32.load8_u (i32.add (local.get $src) (local.get $i)))
								)
								(br $bytes)
							)
						)
						(return)
					)
				)
			)
		)
		(local.set $pattern
			(i64.mul
				(i64.extend_i32_u (i32.and (local.get $source) (i32.const 255)))
				(i64.const 0x0101010101010101)
			)
		)
		;; Stop before a partial trailing slot to keep every native store in the checked range.
		(block $slots-done
			;; Copy forward or fill complete eight-byte slots, without using native bulk instructions.
			(loop $slots
				(br_if $slots-done (i32.lt_u (i32.sub (local.get $length) (local.get $i)) (i32.const 8)))
				;; Copy reads its slot before writing; fill uses the repeated low-byte pattern.
				(if (i32.eq (local.get $op) (i32.const 187))
					(then
						(local.set $pattern (i64.load (i32.add (local.get $src) (local.get $i))))
					)
				)
				(i64.store (i32.add (local.get $dest) (local.get $i)) (local.get $pattern))
				(local.set $i (i32.add (local.get $i) (i32.const 8)))
				(br $slots)
			)
		)
		;; Complete an empty range or the remaining zero to seven trailing bytes.
		(block $done
			;; Increasing offsets keep earlier destinations from destroying unread copy bytes.
			(loop $bytes
				(br_if $done (i32.eq (local.get $i) (local.get $length)))
				;; Fill masks through store8; copy replaces the value with the current source byte.
				(if (i32.eq (local.get $op) (i32.const 187))
					(then
						(local.set $source (i32.load8_u (i32.add (local.get $src) (local.get $i))))
					)
				)
				(i32.store8 (i32.add (local.get $dest) (local.get $i)) (local.get $source))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $bytes)
			)
		)
	)

	;; Execute a resolved data.drop or memory.init, retaining passive bytes until an explicit drop.
	(func $data-use
		(param $op i32)
		(param $index i32)
		(param $destination i32)
		(param $source i32)
		(param $length i32)
		(local $record i32)
		(local $dest i32)
		(local $src i32)
		(local $i i32)

		(local.set $record (call $data-record (local.get $index)))
		;; Dropping active, empty or already-dropped data is always idempotent.
		(if (i32.eq (local.get $op) (i32.const 190))
			(then
				(i32.store offset=44 (local.get $record) (i32.const 0))
				(return)
			)
		)
		;; Source bounds use the segment's remaining length, including the zero-length endpoint rule.
		(if
			(i64.gt_u
				(i64.add (i64.extend_i32_u (local.get $source)) (i64.extend_i32_u (local.get $length)))
				(i64.extend_i32_u (i32.load offset=44 (local.get $record)))
			)
			(then
				(call $fail (i32.const 14))
				(return)
			)
		)
		(local.set $dest
			(call $guest-address (local.get $destination) (i32.const 0) (local.get $length))
		)
		;; Validate the complete destination before any decoded bytes become guest memory.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $src
			(i32.add
				(global.get $data-base)
				(i32.add (i32.load offset=4 (local.get $record)) (local.get $source))
			)
		)
		;; Stop before a partial final slot; decoded data and guest memory occupy disjoint arenas.
		(block $slots-done
			;; Each full slot preserves all bytes, including NaN payloads stored as data.
			(loop $slots
				(br_if $slots-done (i32.lt_u (i32.sub (local.get $length) (local.get $i)) (i32.const 8)))
				(i64.store
					(i32.add (local.get $dest) (local.get $i))
					(i64.load (i32.add (local.get $src) (local.get $i)))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 8)))
				(br $slots)
			)
		)
		;; Complete empty segments or the remaining zero to seven bytes.
		(block $done
			;; Copy each remaining byte without touching adjacent interpreter-owned data.
			(loop $bytes
				(br_if $done (i32.eq (local.get $i) (local.get $length)))
				(i32.store8
					(i32.add (local.get $dest) (local.get $i))
					(i32.load8_u (i32.add (local.get $src) (local.get $i)))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $bytes)
			)
		)
	)
