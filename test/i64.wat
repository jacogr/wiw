(module
	;; Increment a full-width host argument without losing bits above the i32 range.
	(func (export "increment")
		(param $value i64)
		(result i64)

		(i64.add (local.get $value) (i64.const 1))
	)
)
