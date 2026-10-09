	;; Parse the sole start declaration, retaining its function reference until module-wide resolution.
	(func $parse-start
		;; A module may have at most one start declaration, even when both references agree.
		(if (global.get $start-state)
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		(global.set $start-state (i32.const 1))
		(call $next)
		(global.set $start-offset (global.get $tok))
		;; Named starts can refer to functions declared later in the source.
		(if (call $named)
			(then
				(global.set $start-function (global.get $tok))
				(global.set $start-length (global.get $len))
				(call $next)
			)
			;; Numeric starts use the same function index space as calls and exports.
			(else
				(global.set $start-function (call $index))
			)
		)
		(call $expect (i32.const 2))
	)

	;; Resolve a start target against completed signatures and require exactly zero parameters and results.
	(func $resolve-start
		(local $function i32)

		;; Modules without a start declaration need no deferred lookup or signature check.
		(if (i32.eqz (global.get $start-state))
			(then
				(return)
			)
		)
		(global.set $start-function
			(call $target
				(global.get $start-function)
				(global.get $start-length)
				(global.get $start-offset)
			)
		)
		;; A missing target must never be dereferenced as a function record.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $function (call $function (global.get $start-function)))
		;; Even inherited and imported start signatures must be void and accept no arguments.
		(if
			(i32.or
				(i32.load offset=16 (local.get $function))
				(i32.load offset=24 (local.get $function))
			)
			(then
				(global.set $tok (global.get $start-offset))
				(call $fail (i32.const M4_ERR_OPERAND_STACK))
			)
		)
	)

	;; Finalize a start only when execution completes or fails; an import suspension retains its lifecycle state.
	(func $finish-start
		(param $value i64)
		(result i64)

		;; Ordinary invocations and suspended starts leave initialization state unchanged.
		(if
			(i32.and
				(i32.eq (global.get $start-state) (i32.const 2))
				(i32.lt_s (global.get $pending-import) (i32.const 0))
			)
			(then
				(global.set $ready (i32.eqz (global.get $error)))
				(global.set $start-state (select (i32.const 3) (i32.const 0) (global.get $error)))
			)
		)
		(local.get $value)
	)

	;; Run the start once after the host binds all imports; callbacks use the normal suspend/resume protocol.
	(func (export "initialize")
		(result i32)

		;; A host cannot restart initialization while a guest call is suspended.
		(if (i32.ge_s (global.get $pending-import) (i32.const 0))
			(then
				(call $fail (i32.const M4_ERR_SUSPENDED_REENTRY))
				(return (i32.const 22))
			)
		)
		(global.set $error (i32.const M4_ERR_SUCCESS))
		;; Failed loads and failed starts are unavailable until a fresh successful load.
		(if (i32.eqz (global.get $ready))
			(then
				(call $fail (i32.const M4_ERR_NOT_INITIALIZED))
				(return (global.get $error))
			)
		)
		;; Imported resources are bound before applying their segments and executing a start.
		(if (global.get $resource-phase)
			(then
				;; A low-level host must explicitly prepare and bind imported resource descriptors.
				(if (i32.eq (global.get $resource-phase) (i32.const 1))
					(then
						(call $fail (i32.const M4_ERR_NOT_INITIALIZED))
						(return (global.get $error))
					)
				)
				(call $initialize-global-references)
				;; Bound resources and functions remain alive after a later segment traps.
				(global.set $segments-ready (i32.const 1))
				(call $apply-table-initializers)
				(call $apply-elements)
				;; A failed table initializer prevents subsequent memory writes.
				(if (i32.eqz (global.get $error))
					(then
						(call $apply-data)
					)
				)
				(global.set $resource-phase (i32.const 0))
				;; A failed segment prevents the start, while earlier segment effects remain observable.
				(if (global.get $error)
					(then
						(global.set $ready (i32.const 0))
						(global.set $start-state (i32.const 0))
						(return (global.get $error))
					)
				)
			)
		)
		;; Completed resources now root their current values; obsolete initializer copies can be reclaimed.
		(global.set $gc-initializing (i32.const 0))
		;; Initialization is idempotent for modules without a start or with a completed start.
		(if (i32.eqz (global.get $start-state))
			(then
				(return (i32.const 0))
			)
		)
		(global.set $start-state (i32.const 2))
		(global.set $last-results (i32.const 0))
		(global.set $tok (global.get $start-offset))
		(drop (call $finish-start (call $run (global.get $start-function) (i32.const 0))))
		(global.get $error)
	)
