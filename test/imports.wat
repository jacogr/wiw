;; A host supplies integer functions; guest code retains its own stack and memory.
(module
	(import "math" "add"
		;; Declare a host addition function accepting two i32 values.
		(func $add
			(param i32 i32)
			(result i32)
		)
	)
	(import "host" "byte"
		;; Declare a host byte reader accepting a pointer into this guest memory.
		(func $byte
			(param i32)
			(result i32)
		)
	)
	(memory $bytes 1)
	(data (i32.const 32) "*")

	;; Forward scalar arguments to the host function and return 42.
	(func (export "answer")
		(result i32)

		(call $add (i32.const 40) (i32.const 2))
	)

	;; Pass a guest pointer to a callback that reads this instance's memory.
	(func (export "fromMemory")
		(result i32)

		(call $byte (i32.const 32))
	)
)
