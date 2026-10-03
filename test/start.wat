(module
	(start $initialize)
	(memory 1)
	(data (i32.const 0) "*")
	(type $empty (func))
	(table funcref (elem $write))
	(global $count (mut i32) (i32.const 0))

	;; Read initialized data and publish it through a persistent global.
	(func $write
		(i32.store (i32.const 4) (i32.load8_u (i32.const 0)))
		(global.set $count (i32.add (global.get $count) (i32.const 1)))
	)

	;; Run once after data and table initialization, using the shared indirect-call machinery.
	(func $initialize
		(call_indirect (type $empty) (i32.const 0))
	)

	;; Expose the value written by the start function without running it again.
	(func (export "answer")
		(result i32)

		(i32.load (i32.const 4))
	)

	;; Report how many times the start has executed since the most recent load.
	(func (export "count")
		(result i32)

		(global.get $count)
	)
)
