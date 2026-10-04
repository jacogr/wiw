	;; Execute bulk copy/fill only after all unsigned guest ranges pass bounds checks.
	(func $bulk-memory
		(param $op i32)
		(param $destination i32)
		(param $source i32)
		(param $length i32)
		(local $dest i32)
		(local $src i32)

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
				(memory.copy (local.get $dest) (local.get $src) (local.get $length))
				(return)
			)
		)
		(memory.fill (local.get $dest) (local.get $source) (local.get $length))
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
		(memory.copy (local.get $dest) (local.get $src) (local.get $length))
	)
