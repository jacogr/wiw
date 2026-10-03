(module
	;; A guest arithmetic fixture: evaluate 7 * 8 - (10 + 4), yielding 42.
	(func (export "answer")
		(result i32)

		(i32.sub
			(i32.mul (i32.const 7) (i32.const 8))
			(i32.add (i32.const 10) (i32.const 4))
		)
	)
)
