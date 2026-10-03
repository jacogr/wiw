(module
	;; Sum the positive integers up to n, using explicit labels for loop exit and repetition.
	(func (export "sum")
		(param $n i32)
		(result i32)
		(local $total i32)

		;; Exit to the result once the counter reaches zero.
		(block $done
			;; Accumulate one term and count down before returning to the loop label.
			(loop $again
				(br_if $done (i32.eqz (local.get $n)))
				(local.set $total (i32.add (local.get $total) (local.get $n)))
				(local.set $n (i32.sub (local.get $n) (i32.const 1)))
				(br $again)
			)
		)
		(local.get $total)
	)

	;; Compute factorial recursively, returning one i32 with wrapping multiplication.
	(func $factorial (export "factorial")
		(param $n i32)
		(result i32)

		;; Zero and one are the base cases; larger unsigned values recurse.
		(if (result i32) (i32.le_u (local.get $n) (i32.const 1))
			(then
				(i32.const 1)
			)
			;; Multiply this frame's n by the result from the next recursive frame.
			(else
				(i32.mul
					(local.get $n)
					(call $factorial (i32.sub (local.get $n) (i32.const 1)))
				)
			)
		)
	)
)
