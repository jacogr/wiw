(module
	;; A minimal guest fixture: return 42 from the exported answer function.
	(func (export "answer")
		(result i32)

		(i32.const 42)
	)
)
