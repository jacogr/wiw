(module
	(type $wide (func (param i64) (result i64)))
	(type $small (func (param i32) (result i32)))
	(table funcref (elem $increment $factorial))

	;; Increment a wide argument after inheriting its parameter/result types.
	(func $increment
		(type $wide)

		(i64.add (local.get 0) (i64.const 1))
	)

	;; Dispatch a wide argument through the table's first slot.
	(func (export "increment")
		(type $wide)

		(call_indirect (type $wide) (local.get 0) (i32.const 0))
	)

	;; Compute factorial with recursive indirect calls through the second table slot.
	(func $factorial (export "factorial")
		(type $small)

		;; Zero is the base case; positive arguments multiply by the next recursive result.
		(if (result i32) (i32.eqz (local.get 0))
			(then
				(i32.const 1)
			)
			;; Preserve this frame's argument while dispatching the reduced argument indirectly.
			(else
				(i32.mul
					(local.get 0)
					(call_indirect (type $small)
						(i32.sub (local.get 0) (i32.const 1))
						(i32.const 1)
					)
				)
			)
		)
	)
)
