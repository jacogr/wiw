;; Active bytes and persistent state share a guest instance across invocations.
(module
	(memory $bytes (export "bytes") 1 4)
	(global $count (export "count") (mut i32) (i32.const 0))
	(data (i32.const 0) "\0a\14\0c")

	;; Add the three initialized unsigned bytes to produce 42.
	(func (export "answer")
		(result i32)

		(i32.add
			(i32.add
				(i32.load8_u (i32.const 0))
				(i32.load8_u (i32.const 1))
			)
			(i32.load8_u (i32.const 2))
		)
	)

	;; Advance the persistent counter and return its new value.
	(func (export "next")
		(param $delta i32)
		(result i32)

		(global.set $count
			(i32.add (global.get $count) (local.get $delta))
		)
		(global.get $count)
	)

	;; Store an arbitrary i32 at a guest byte address, including unaligned addresses.
	(func (export "put")
		(param $address i32)
		(param $value i32)

		(i32.store (local.get $address) (local.get $value))
	)
)
