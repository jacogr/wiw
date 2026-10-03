(module
	(memory 1)
	(type $double (func (param f64) (result f64)))
	(table funcref (elem $scale))

	;; Double a double-precision argument through a typed indirect call.
	(func $scale (type $double)
		(f64.mul (local.get 0) (f64.const 2))
	)

	;; Preserve raw float bits through a local and an unaligned memory round trip.
	(func (export "double")
		(param $value f64)
		(result f64)
		(local $saved f64)

		(local.set $saved (local.get $value))
		(f64.store offset=1 align=1 (i32.const 0) (local.get $saved))
		(call_indirect (type $double)
			(f64.load offset=1 align=1 (i32.const 0))
			(i32.const 0)
		)
	)

	;; Round a decimal literal directly to single precision inside the interpreter.
	(func (export "rounded")
		(result f32)

		(f32.const 1.00000006)
	)

	;; Return a signed zero through a typed conditional result.
	(func (export "zero")
		(param $choose i32)
		(result f64)

		;; The selected arm produces a double-precision value with its original sign bit.
		(if (result f64) (local.get $choose)
			(then
				(f64.const -0)
			)
			;; The other arm returns a hexadecimal constant parsed by the same WAT engine.
			(else
				(f64.const 0x1.8p1)
			)
		)
	)
)
