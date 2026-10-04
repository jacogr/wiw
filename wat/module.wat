	;; Test whether the current token is an atom with the given keyword bytes.
	(func $is-word
		(param $p i32)
		(param $n i32)
		(result i32)

		(i32.and
			(i32.eq (global.get $kind) (i32.const 3))
			(i32.and
				(i32.eq (global.get $len) (local.get $n))
				(call $equal (global.get $tok) (local.get $p) (local.get $n))
			)
		)
	)

	;; Recognize a source-backed identifier by its leading dollar sign.
	(func $named
		(result i32)

		(i32.and
			(i32.eq (global.get $kind) (i32.const 3))
			(i32.and
				(i32.ne (global.get $len) (i32.const 0))
				(i32.eq (i32.load8_u (global.get $tok)) (i32.const 36))
			)
		)
	)

	;; Decode an unsigned numeric index, rejecting signed spellings before integer conversion.
	(func $index
		(result i32)

		;; An index must begin with a decimal digit, including the zero in a hex prefix.
		(if
			(i32.or
				(i32.ne (global.get $kind) (i32.const 3))
				(i32.or
					(i32.lt_u (i32.load8_u (global.get $tok)) (i32.const 48))
					(i32.gt_u (i32.load8_u (global.get $tok)) (i32.const 57))
				)
			)
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(call $integer)
	)

	;; Locate a function's 32-byte record.
	;; Offsets 0/4: identifier pointer/length; 8/12: instruction start/end, or -1/import slot.
	;; Offsets 16/20: parameter count/total local slots; 24/28: result type/source offset.
	(func $function
		(param $index i32)
		(result i32)

		(i32.add (global.get $function-base) (i32.mul (local.get $index) (i32.const 32)))
	)

	;; Locate one local-name record in the current function's bounded local namespace.
	(func $local-name
		(param $index i32)
		(result i32)

		(i32.add
			(global.get $local-name-base)
			(i32.add
				(i32.mul (global.get $current-function) (i32.const LOCAL_NAME_BYTES))
				(i32.mul (local.get $index) (i32.const 8))
			)
		)
	)

	;; Find a function name in module scope; return its index or -1 when absent.
	(func $find-function
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Exhausting the function table reaches the not-found result below.
		(block $missing
			;; Search earlier records in source order; anonymous functions have no matching name.
			(loop $search
				(br_if $missing (i32.eq (local.get $i) (global.get $function-count)))
				(local.set $record (call $function (local.get $i)))
				;; Match both the source span length and identifier bytes.
				(if
					(i32.and
						(i32.eq (i32.load offset=4 (local.get $record)) (local.get $n))
						(call $equal (i32.load (local.get $record)) (local.get $p) (local.get $n))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $search)
			)
		)
		(i32.const -1)
	)

	;; Find a parameter/local name only within the current function; return its index or -1.
	(func $find-local
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $i i32)
		(local $count i32)
		(local $record i32)

		(local.set $count (i32.load offset=20 (call $function (global.get $current-function))))
		;; Exhausting this function's local declarations means the name is unknown.
		(block $missing
			;; Parameters occupy the first indices; declared locals follow them.
			(loop $search
				(br_if $missing (i32.eq (local.get $i) (local.get $count)))
				(local.set $record (call $local-name (local.get $i)))
				;; Unnamed declarations have zero-length spans and cannot match a dollar-prefixed name.
				(if
					(i32.and
						(i32.eq (i32.load offset=4 (local.get $record)) (local.get $n))
						(call $equal (i32.load (local.get $record)) (local.get $p) (local.get $n))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $search)
			)
		)
		(i32.const -1)
	)

	;; Register one inline or module-level export, checking duplicate names and table capacity.
	;; A nonzero target-name length defers target resolution until the module is complete.
	(func $add-export
		(param $p i32)
		(param $n i32)
		(param $target i32)
		(param $target-length i32)
		(param $offset i32)
		(param $category i32)
		(local $i i32)
		(local $record i32)

		;; Preserve an existing parse error without publishing an incomplete export.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(local.set $p (call $export-name (local.get $p) (local.get $n)))
		(local.set $n (global.get $decoded-name-length))
		;; Reject unsupported name spellings before recording the export.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Bound the export table before its next entry could reach the call-frame region.
		(if (i32.ge_u (global.get $export-count) (i32.const 512))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		;; Stop checking once every existing export name has been compared.
		(block $checked
			;; Empty names are valid too, so compare lengths before bytes for every entry.
			(loop $search
				(br_if $checked (i32.eq (local.get $i) (global.get $export-count)))
				(local.set $record
					(i32.add (global.get $export-base) (i32.mul (local.get $i) (i32.const 32)))
				)
				;; Duplicate export names are invalid across all resource kinds and target indices.
				(if
					(i32.and
						(i32.eq (i32.load offset=4 (local.get $record)) (local.get $n))
						(call $equal (i32.load (local.get $record)) (local.get $p) (local.get $n))
					)
					(then
						(global.set $tok (local.get $offset))
						(call $fail (i32.const 10))
						(return)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $search)
			)
		)
		(local.set $record
			(i32.add (global.get $export-base) (i32.mul (global.get $export-count) (i32.const 32)))
		)
		(i32.store (local.get $record) (local.get $p))
		(i32.store offset=4 (local.get $record) (local.get $n))
		(i32.store offset=8 (local.get $record) (local.get $target))
		(i32.store offset=12 (local.get $record) (local.get $target-length))
		(i32.store offset=16 (local.get $record) (local.get $offset))
		(i32.store offset=20 (local.get $record) (local.get $category))
		(global.set $export-count (i32.add (global.get $export-count) (i32.const 1)))
	)

	;; Add one typed scalar parameter or local, assigning its index and enforcing per-function name uniqueness.
	(func $add-local
		(param $p i32)
		(param $n i32)
		(param $parameter i32)
		(param $type i32)
		(local $f i32)
		(local $count i32)
		(local $record i32)

		(local.set $f (call $function (global.get $current-function)))
		(local.set $count (i32.load offset=20 (local.get $f)))
		;; Parameters retain their ABI bound; declared locals use the larger frame capacity.
		(if
			(i32.ge_u
				(local.get $count)
				(select (i32.const 128) (i32.const CAP_LOCALS) (local.get $parameter))
			)
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		;; Named declarations must not reuse an existing parameter or local identifier.
		(if (local.get $n)
			(then
				;; The shared namespace covers both parameters and declared locals.
				(if (i32.ne (call $find-local (local.get $p) (local.get $n)) (i32.const -1))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
			)
		)
		(local.set $record (call $local-name (local.get $count)))
		(i32.store (local.get $record) (local.get $p))
		(i32.store offset=4 (local.get $record) (local.get $n))
		(i32.store8
			(call $local-type (global.get $current-function) (local.get $count))
			(local.get $type)
		)
		(i32.store offset=20 (local.get $f) (i32.add (local.get $count) (i32.const 1)))
		;; Parameters are copied from call arguments; later locals begin as zero.
		(if (local.get $parameter)
			(then
				(i32.store offset=16
					(local.get $f)
					(i32.add (i32.load offset=16 (local.get $f)) (i32.const 1))
				)
			)
		)
	)

	;; Parse a param/local declaration after its keyword, accepting named singles or unnamed groups.
	(func $declarations
		(param $parameter i32)
		(local $p i32)
		(local $n i32)
		(local $type i32)

		(call $next)
		;; A named declaration binds exactly one integer slot.
		(if (call $named)
			(then
				(local.set $p (global.get $tok))
				(local.set $n (global.get $len))
				(call $next)
				(local.set $type (call $value-type))
				(call $add-local (local.get $p) (local.get $n) (local.get $parameter) (local.get $type))
			)
			;; Unnamed groups may contain any mix of scalar slots, including none.
			(else
				;; Finish when the declaration's closing parenthesis is reached.
				(block $done
					;; Add one unnamed local for each type atom, stopping on the first failure.
					(loop $types
						(br_if $done (global.get $error))
						(br_if $done (i32.eq (global.get $kind) (i32.const 2)))
						(local.set $type (call $value-type))
						(call $add-local (i32.const 0) (i32.const 0) (local.get $parameter) (local.get $type))
						(br $types)
					)
				)
			)
		)
		(call $expect (i32.const 2))
	)

	;; Parse a defined function or import signature, with module names and ordered declarations.
	;; Header declarations precede body instructions; forward call names remain unresolved here.
	(func $parse-function
		(local $f i32)
		(local $p i32)
		(local $n i32)
		(local $open i32)
		(local $phase i32)
		(local $category i32)
		(local $offset i32)
		(local $result-type i32)
		(local $type-meta i32)
		(local $inline-import i32)

		(local.set $offset (global.get $tok))
		(call $next)
		;; Function capacity bounds every related function/local-name table.
		(if (i32.ge_u (global.get $function-count) (i32.const CAP_FUNCTIONS))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		;; A dollar-prefixed function name is optional; anonymous functions keep numeric indices.
		(if (call $named)
			(then
				(local.set $p (global.get $tok))
				(local.set $n (global.get $len))
				;; Function names must be unique across the module.
				(if (i32.ne (call $find-function (local.get $p) (local.get $n)) (i32.const -1))
					(then
						(call $fail (i32.const 10))
						(return)
					)
				)
				(call $next)
			)
		)
		(global.set $current-function (global.get $function-count))
		(local.set $f (call $function (global.get $current-function)))
		(i32.store (local.get $f) (local.get $p))
		(i32.store offset=4 (local.get $f) (local.get $n))
		(i32.store offset=8 (local.get $f) (global.get $code-count))
		(i32.store offset=16 (local.get $f) (i32.const 0))
		(i32.store offset=20 (local.get $f) (i32.const 0))
		(i32.store offset=24 (local.get $f) (i32.const 0))
		(i32.store offset=28 (local.get $f) (local.get $offset))
		(local.set $type-meta (call $function-type (global.get $current-function)))
		(call $zero-bytes (local.get $type-meta) (i32.const 32))
		(global.set $function-count (i32.add (global.get $function-count) (i32.const 1)))
		;; Leave header parsing as soon as the next parenthesized form is an instruction.
		(block $body-start
			;; Consume ordered export, param, result and local declarations.
			(loop $header
				(br_if $body-start (global.get $error))
				(br_if $body-start (i32.ne (global.get $kind) (i32.const 1)))
				(local.set $open (global.get $tok))
				(call $next)
				(local.set $category (i32.const -1))
				;; Inline imports abbreviate a module import while retaining this function's identity and exports.
				(if (call $is-word (i32.const 112) (i32.const 6))
					(then
						;; An import annotation occurs once and precedes all signature declarations.
						(if (i32.or (local.get $phase) (global.get $parsing-import))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $read-import-names (global.get $current-function))
						(call $expect (i32.const 2))
						(local.set $inline-import (i32.const 1))
						(global.set $parsing-import (i32.const 1))
						(br $header)
					)
				)
				;; Type uses precede inline parameters/results; forward references are applied after parsing.
				(if (call $is-word (i32.const 3856) (i32.const 4))
					(then
						;; Export annotations may precede the type use, but signature/local declarations may not.
						(if (local.get $phase)
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $read-type-use (local.get $type-meta))
						(br $header)
					)
				)
				;; Inline exports appear before the signature declarations.
				(if (call $is-word (i32.const 11) (i32.const 6))
					(then
						(local.set $category (i32.const 0))
					)
				)
				;; Parameters precede results and locals in the function header.
				(if (call $is-word (i32.const 64) (i32.const 5))
					(then
						(local.set $category (i32.const 1))
					)
				)
				;; A function may declare zero or one scalar result in this subset.
				(if (call $is-word (i32.const 17) (i32.const 6))
					(then
						(local.set $category (i32.const 2))
					)
				)
				;; Declared locals follow all signature declarations.
				(if (call $is-word (i32.const 69) (i32.const 5))
					(then
						(local.set $category (i32.const 3))
					)
				)
				;; An unrecognized declaration head belongs to the body; replay its opening token.
				(if (i32.eq (local.get $category) (i32.const -1))
					(then
						(global.set $pos (local.get $open))
						(call $next)
						(br $body-start)
					)
				)
				;; Later header categories cannot be followed by earlier ones.
				(if (i32.lt_u (local.get $category) (local.get $phase))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				;; Import descriptors permit only parameter and result declarations.
				(if
					(i32.and
						(global.get $parsing-import)
						(i32.or
							(i32.and (i32.eqz (local.get $category)) (i32.eqz (local.get $inline-import)))
							(i32.eq (local.get $category) (i32.const 3))
						)
					)
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				;; Record inline groups independently from their optional explicit type use.
				(if
					(i32.or
						(i32.eq (local.get $category) (i32.const 1))
						(i32.eq (local.get $category) (i32.const 2))
					)
					(then
						(i32.store offset=16 (local.get $type-meta) (i32.const 1))
					)
				)
				(local.set $phase (local.get $category))
				;; Capture inline export names while retaining the current numeric function index.
				(if (i32.eqz (local.get $category))
					(then
						(call $next)
						(local.set $p (global.get $tok))
						(local.set $n (global.get $len))
						(call $expect (i32.const 4))
						(call $expect (i32.const 2))
						(call $add-export
							(local.get $p)
							(local.get $n)
							(global.get $current-function)
							(i32.const 0)
							(local.get $open)
							(i32.const 0)
						)
						(br $header)
					)
				)
				;; Parameter and local groups share type/name parsing but differ in signature effects.
				(if
					(i32.or
						(i32.eq (local.get $category) (i32.const 1))
						(i32.eq (local.get $category) (i32.const 3))
					)
					(then
						(call $declarations (i32.eq (local.get $category) (i32.const 1)))
						(br $header)
					)
				)
				(call $next)
				;; Collect ordered results across all result groups.
				(block $results-done
					;; Each parsed type appends to the function's bounded result shape.
					(loop $results
						(br_if $results-done (global.get $error))
						(br_if $results-done (i32.eq (global.get $kind) (i32.const 2)))
						(i32.store offset=24
							(local.get $f)
							(call $shape-append (i32.load offset=24 (local.get $f)) (call $value-type))
						)
						(br $results)
					)
				)
				(call $expect (i32.const 2))
				(br $header)
			)
		)
		;; Imported functions have a signature and import slot, but no instruction body.
		(if (global.get $parsing-import)
			(then
				;; Function imports must precede defined functions independently of other resources.
				(if (i32.and (global.get $definitions-started) (i32.const 1))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(i32.store offset=8 (local.get $f) (i32.const -1))
				(i32.store offset=12 (local.get $f) (global.get $import-count))
				(call $expect (i32.const 2))
				;; Inline imports own publication; outer imports publish after their descriptor closes.
				(if (local.get $inline-import)
					(then
						(global.set $parsing-import (i32.const 0))
						(global.set $import-count (i32.add (global.get $import-count) (i32.const 1)))
					)
				)
				(return)
			)
		)
		(global.set $definitions-started (i32.or (global.get $definitions-started) (i32.const 1)))
		(call $body)
		(i32.store offset=12 (local.get $f) (global.get $code-count))
		(call $expect (i32.const 2))
	)

	;; Parse a typed module-level export, preserving forward names for its resource namespace.
	(func $parse-export
		(local $category i32)
		(local $p i32)
		(local $n i32)
		(local $target i32)
		(local $length i32)
		(local $offset i32)

		(local.set $offset (global.get $tok))
		(call $next)
		(local.set $p (global.get $tok))
		(local.set $n (global.get $len))
		(call $expect (i32.const 4))
		(call $expect (i32.const 1))
		(local.set $category (call $export-kind))
		(call $next)
		;; A named target can refer to the appropriate resource declared later in the module.
		(if (call $named)
			(then
				(local.set $target (global.get $tok))
				(local.set $length (global.get $len))
				(call $next)
			)
			;; Numeric targets identify resources by index within their own namespace.
			(else
				(local.set $target (call $index))
			)
		)
		(call $expect (i32.const 2))
		(call $expect (i32.const 2))
		(call $add-export
			(local.get $p)
			(local.get $n)
			(local.get $target)
			(local.get $length)
			(local.get $offset)
			(local.get $category)
		)
	)

	;; Resolve a source-backed function name or check a numeric target; return the final index.
	(func $target
		(param $value i32)
		(param $length i32)
		(param $offset i32)
		(result i32)

		;; Named targets need a module-scope lookup; numeric targets are already indices.
		(if (local.get $length)
			(then
				(local.set $value (call $find-function (local.get $value) (local.get $length)))
			)
		)
		;; Unknown names return -1, which is also outside the valid unsigned index range.
		(if (i32.ge_u (local.get $value) (global.get $function-count))
			(then
				(global.set $tok (local.get $offset))
				(call $fail (i32.const 10))
			)
		)
		(local.get $value)
	)

	;; Resolve calls, globals and typed exports, then validate every function stack and resource access.
	(func $resolve-and-validate
		(local $i i32)
		(local $record i32)

		(call $intern-function-types)
		(call $resolve-signatures)
		(call $resolve-control-signatures)
		(call $resolve-elements)
		(call $resolve-reference-globals)
		;; End call resolution when all instruction records have been checked.
		(block $calls-done
			;; Rewrite named call immediates into numeric function indices exactly once.
			(loop $calls
				(br_if $calls-done (i32.eq (local.get $i) (global.get $code-count)))
				(local.set $record
					(i32.add (global.get $code-base) (i32.mul (local.get $i) (i32.const 16)))
				)
				;; Direct calls resolve against the completed function namespace.
				(if
					(i32.or
						(i32.eq (i32.load (local.get $record)) (i32.const 36))
						(i32.eq (i32.load (local.get $record)) (i32.const 195))
					)
					(then
						(i32.store offset=4
							(local.get $record)
							(call $target
								(i32.load offset=4 (local.get $record))
								(i32.load offset=12 (local.get $record))
								(i32.load offset=8 (local.get $record))
							)
						)
					)
				)
				;; Global names resolve only after the entire module namespace is available.
				(if
					(i32.and
						(i32.ge_u (i32.load (local.get $record)) (i32.const 49))
						(i32.le_u (i32.load (local.get $record)) (i32.const 50))
					)
					(then
						(i32.store offset=4
							(local.get $record)
							(call $resource-target
								(i32.const 2)
								(i32.load offset=4 (local.get $record))
								(i32.load offset=12 (local.get $record))
								(i32.load offset=8 (local.get $record))
							)
						)
					)
				)
				(br_if $calls-done (global.get $error))
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $calls)
			)
		)
		(local.set $i (i32.const 0))
		;; Finish export resolution after every name/index target has been checked.
		(block $exports-done
			;; Convert source-backed export targets into indices within their declared resource namespace.
			(loop $exports
				(br_if $exports-done (global.get $error))
				(br_if $exports-done (i32.eq (local.get $i) (global.get $export-count)))
				(local.set $record
					(i32.add (global.get $export-base) (i32.mul (local.get $i) (i32.const 32)))
				)
				(i32.store offset=8
					(local.get $record)
					(call $resource-target
						(i32.load offset=20 (local.get $record))
						(i32.load offset=8 (local.get $record))
						(i32.load offset=12 (local.get $record))
						(i32.load offset=16 (local.get $record))
					)
				)
				;; Exported functions belong to the declaration set required by ref.func bodies.
				(if (i32.eqz (i32.load offset=20 (local.get $record)))
					(then
						(call $declare-function (i32.load offset=8 (local.get $record)))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $exports)
			)
		)
		(local.set $i (i32.const 0))
		;; Validate each resolved function independently, including its implicit return label.
		(block $done
			;; Stop at the first failure; unresolved or invalid code is never executable.
			(loop $functions
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $function-count)))
				;; Imported signatures participate in calls, but contain no code to validate.
				(if (i32.ne (i32.load offset=8 (call $function (local.get $i))) (i32.const -1))
					(then
						(call $validate-function (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $functions)
			)
		)
	)
