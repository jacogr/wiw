(module
	;; Return the difference between two host-provided i32 arguments.
	(func $subtract (export "subtract")
		(param $a i32)
		(param $b i32)
		(result i32)

		(i32.sub (local.get $a) (local.get $b))
	)

	;; Call the named helper with folded arguments, yielding 42.
	(func (export "answer")
		(result i32)

		(call $subtract (i32.const 100) (i32.const 58))
	)
)
