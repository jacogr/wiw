	;; Decode one ASCII hexadecimal digit; return -1 for any other byte.
	(func $hex
		(param $c i32)
		(result i32)

		;; Decimal digits contribute values zero through nine.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 48))
				(i32.le_u (local.get $c) (i32.const 57))
			)
			(then
				(return (i32.sub (local.get $c) (i32.const 48)))
			)
		)
		;; Lowercase letters contribute values ten through fifteen.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 97))
				(i32.le_u (local.get $c) (i32.const 102))
			)
			(then
				(return (i32.sub (local.get $c) (i32.const 87)))
			)
		)
		;; Uppercase hexadecimal spellings are equivalent.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 65))
				(i32.le_u (local.get $c) (i32.const 70))
			)
			(then
				(return (i32.sub (local.get $c) (i32.const 55)))
			)
		)
		(i32.const -1)
	)

	;; Append one decoded data byte without letting the data arena overwrite guest memory.
	(func $data-byte
		(param $c i32)

		;; Preserve the first failure and bound the shared decoded-data capacity.
		(if (global.get $error)
			(then
				(return)
			)
		)
		;; Data capacity is independent from the logical memory size and source length.
		(if (i32.ge_u (global.get $data-count) (i32.const 65536))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(i32.store8 (i32.add (global.get $data-base) (global.get $data-count)) (local.get $c))
		(global.set $data-count (i32.add (global.get $data-count) (i32.const 1)))
	)

	;; Append the UTF-8 encoding of a valid Unicode scalar to the decoded-data arena.
	(func $data-scalar
		(param $c i32)

		;; ASCII scalars need one byte.
		(if (i32.lt_u (local.get $c) (i32.const 128))
			(then
				(call $data-byte (local.get $c))
				(return)
			)
		)
		;; Scalars below 0x800 need two bytes.
		(if (i32.lt_u (local.get $c) (i32.const 2048))
			(then
				(call $data-byte (i32.or (i32.const 192) (i32.shr_u (local.get $c) (i32.const 6))))
				(call $data-byte (i32.or (i32.const 128) (i32.and (local.get $c) (i32.const 63))))
				(return)
			)
		)
		;; Remaining BMP scalars need three bytes; surrogate values were rejected by the decoder.
		(if (i32.lt_u (local.get $c) (i32.const 65536))
			(then
				(call $data-byte (i32.or (i32.const 224) (i32.shr_u (local.get $c) (i32.const 12))))
				(call $data-byte
					(i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $c) (i32.const 6)) (i32.const 63)))
				)
				(call $data-byte (i32.or (i32.const 128) (i32.and (local.get $c) (i32.const 63))))
				(return)
			)
		)
		(call $data-byte (i32.or (i32.const 240) (i32.shr_u (local.get $c) (i32.const 18))))
		(call $data-byte
			(i32.or
				(i32.const 128)
				(i32.and (i32.shr_u (local.get $c) (i32.const 12)) (i32.const 63))
			)
		)
		(call $data-byte
			(i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $c) (i32.const 6)) (i32.const 63)))
		)
		(call $data-byte (i32.or (i32.const 128) (i32.and (local.get $c) (i32.const 63))))
	)

	;; Decode a data string's raw UTF-8 bytes, byte escapes, short escapes and Unicode scalar escapes.
	(func $decode-data
		(local $p i32)
		(local $end i32)
		(local $c i32)
		(local $digit i32)
		(local $v i32)
		(local $count i32)
		(local $width i32)
		(local $j i32)

		(local.set $p (global.get $tok))
		(local.set $end (i32.add (local.get $p) (global.get $len)))
		;; Complete the string when all raw content bytes have been consumed.
		(block $done
			;; Escapes may consume several raw bytes while appending one or more decoded bytes.
			(loop $bytes
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $p) (local.get $end)))
				(local.set $c (i32.load8_u (local.get $p)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				;; Unescaped source text must be valid UTF-8 before its bytes become guest data.
				(if (i32.ne (local.get $c) (i32.const 92))
					(then
						(local.set $p (i32.sub (local.get $p) (i32.const 1)))
						(local.set $width (call $utf8-length (local.get $p) (local.get $end)))
						;; Invalid encodings must not be copied into the decoded-data arena.
						(if (global.get $error)
							(then
								(return)
							)
						)
						(local.set $j (i32.const 0))
						;; Complete the validated scalar before resuming escape scanning.
						(block $raw-done
							;; Append each encoded byte unchanged, including multibyte UTF-8 text.
							(loop $raw
								(br_if $raw-done (i32.eq (local.get $j) (local.get $width)))
								(call $data-byte (i32.load8_u (i32.add (local.get $p) (local.get $j))))
								(local.set $j (i32.add (local.get $j) (i32.const 1)))
								(br $raw)
							)
						)
						(local.set $p (i32.add (local.get $p) (local.get $width)))
						(br $bytes)
					)
				)
				;; A trailing backslash cannot encode a complete escape.
				(if (i32.eq (local.get $p) (local.get $end))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(local.set $c (i32.load8_u (local.get $p)))
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				(local.set $digit (call $hex (local.get $c)))
				;; Two hex digits encode one arbitrary byte, including NUL and non-UTF-8 data.
				(if (i32.ne (local.get $digit) (i32.const -1))
					(then
						;; Require the second byte before attempting to read it.
						(if (i32.eq (local.get $p) (local.get $end))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(local.set $v (call $hex (i32.load8_u (local.get $p))))
						;; A non-hex second digit makes the byte escape malformed.
						(if (i32.eq (local.get $v) (i32.const -1))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(call $data-byte (i32.or (i32.shl (local.get $digit) (i32.const 4)) (local.get $v)))
						(local.set $p (i32.add (local.get $p) (i32.const 1)))
						(br $bytes)
					)
				)
				;; Common control escapes map to their single byte values.
				(if (i32.eq (local.get $c) (i32.const 110))
					(then
						(call $data-byte (i32.const 10))
						(br $bytes)
					)
				)
				;; Tab is escaped because literal control bytes are forbidden in strings.
				(if (i32.eq (local.get $c) (i32.const 116))
					(then
						(call $data-byte (i32.const 9))
						(br $bytes)
					)
				)
				;; Carriage return follows the same short escape convention.
				(if (i32.eq (local.get $c) (i32.const 114))
					(then
						(call $data-byte (i32.const 13))
						(br $bytes)
					)
				)
				;; Quoted punctuation and backslashes retain their literal byte value.
				(if
					(i32.or
						(i32.eq (local.get $c) (i32.const 34))
						(i32.or (i32.eq (local.get $c) (i32.const 39)) (i32.eq (local.get $c) (i32.const 92)))
					)
					(then
						(call $data-byte (local.get $c))
						(br $bytes)
					)
				)
				;; All remaining supported escapes use a Unicode scalar in braces.
				(if
					(i32.or
						(i32.ne (local.get $c) (i32.const 117))
						(i32.ge_u (local.get $p) (local.get $end))
					)
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				;; The Unicode escape requires an opening brace immediately after u.
				(if (i32.ne (i32.load8_u (local.get $p)) (i32.const 123))
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(local.set $p (i32.add (local.get $p) (i32.const 1)))
				(local.set $v (i32.const 0))
				(local.set $count (i32.const 0))
				;; Closing brace completes the scalar value; absent braces are a syntax error.
				(block $scalar-done
					;; Accumulate scalar digits while bounding the value before multiplication can wrap.
					(loop $scalar
						;; EOF before a closing brace is malformed.
						(if (i32.ge_u (local.get $p) (local.get $end))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(local.set $c (i32.load8_u (local.get $p)))
						(local.set $p (i32.add (local.get $p) (i32.const 1)))
						(br_if $scalar-done (i32.eq (local.get $c) (i32.const 125)))
						(local.set $digit (call $hex (local.get $c)))
						;; Only hexadecimal digits are allowed in a Unicode scalar escape.
						(if (i32.eq (local.get $digit) (i32.const -1))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(local.set $v (i32.add (i32.mul (local.get $v) (i32.const 16)) (local.get $digit)))
						;; Reject scalars above the Unicode range before another digit can overflow.
						(if (i32.gt_u (local.get $v) (i32.const 1114111))
							(then
								(call $fail (i32.const 1))
								(return)
							)
						)
						(local.set $count (i32.add (local.get $count) (i32.const 1)))
						(br $scalar)
					)
				)
				;; Empty scalars and UTF-16 surrogates are invalid.
				(if
					(i32.or
						(i32.eqz (local.get $count))
						(i32.and
							(i32.ge_u (local.get $v) (i32.const 55296))
							(i32.le_u (local.get $v) (i32.const 57343))
						)
					)
					(then
						(call $fail (i32.const 1))
						(return)
					)
				)
				(call $data-scalar (local.get $v))
				(br $bytes)
			)
		)
		(call $next)
	)

	;; Decode concatenated strings and publish an active segment at the supplied offset; return its byte length.
	(func $data-segment
		(param $offset i32)
		(param $source i32)
		(result i32)
		(local $record i32)
		(local $start i32)

		;; Segment metadata has its own bounded arena.
		(if (i32.ge_u (global.get $segment-count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return (i32.const 0))
			)
		)
		(local.set $start (global.get $data-count))
		;; Finish string concatenation at the segment's closing parenthesis.
		(block $done
			;; Adjacent strings contribute bytes to the same active segment.
			(loop $strings
				(br_if $done (global.get $error))
				(br_if $done (i32.ne (global.get $kind) (i32.const 4)))
				(call $decode-data)
				(br $strings)
			)
		)
		(call $expect (i32.const 2))
		;; Failed string decoding or syntax must not publish a partially initialized segment.
		(if (global.get $error)
			(then
				(return (i32.const 0))
			)
		)
		(local.set $record
			(i32.add (global.get $segment-base) (i32.mul (global.get $segment-count) (i32.const 48)))
		)
		(i32.store (local.get $record) (local.get $offset))
		(i32.store offset=4 (local.get $record) (local.get $start))
		(i32.store offset=8
			(local.get $record)
			(i32.sub (global.get $data-count) (local.get $start))
		)
		(i32.store offset=12 (local.get $record) (local.get $source))
		(global.set $segment-count (i32.add (global.get $segment-count) (i32.const 1)))
		(i32.sub (global.get $data-count) (local.get $start))
	)

	;; Locate a data segment's 48-byte descriptor, including name, mode and remaining runtime length.
	(func $data-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $segment-base) (i32.mul (local.get $index) (i32.const 48)))
	)

	;; Resolve a data identifier or numeric index after every segment declaration is available.
	(func $data-target
		(param $value i32)
		(param $length i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Numeric references use the complete active/passive source-order index space.
		(if (i32.eqz (local.get $length))
			(then
				;; Out-of-range references remain invalid even in unreachable code.
				(if (i32.ge_u (local.get $value) (global.get $segment-count))
					(then
						(call $fail (i32.const 10))
					)
				)
				(return (local.get $value))
			)
		)
		;; Stop once all named segment records have been searched.
		(block $done
			;; Compare full source-backed names without conflating segment and memory namespaces.
			(loop $names
				(br_if $done (i32.eq (local.get $i) (global.get $segment-count)))
				(local.set $record (call $data-record (local.get $i)))
				;; The first exact match selects a declared segment.
				(if
					(i32.and
						(i32.eq (local.get $length) (i32.load offset=36 (local.get $record)))
						(call $equal
							(local.get $value)
							(i32.load offset=32 (local.get $record))
							(local.get $length)
						)
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(call $fail (i32.const 10))
		(i32.const 0)
	)

	;; Parse an optional segment name followed by an active offset or passive string payload.
	(func $parse-data
		(local $source i32)
		(local $offset i32)
		(local $reference i32)
		(local $name i32)
		(local $length i32)
		(local $open i32)
		(local $passive i32)
		(local $record i32)
		(local $i i32)

		;; Bound the next descriptor before parsing a header into its target fields.
		(if (i32.ge_u (global.get $segment-count) (i32.const 128))
			(then
				(call $fail (i32.const 6))
				(return)
			)
		)
		(local.set $source (global.get $tok))
		(call $next)
		;; Segment identifiers belong to their own namespace and must be unique.
		(if (call $named)
			(then
				(local.set $name (global.get $tok))
				(local.set $length (global.get $len))
				;; Complete duplicate checks before publishing any new descriptor.
				(block $done
					;; Earlier declarations have already recorded their complete name spans.
					(loop $names
						(br_if $done (i32.eq (local.get $i) (global.get $segment-count)))
						(local.set $record (call $data-record (local.get $i)))
						;; Duplicate names are declaration errors regardless of segment mode.
						(if
							(i32.and
								(i32.eq (local.get $length) (i32.load offset=36 (local.get $record)))
								(call $equal
									(local.get $name)
									(i32.load offset=32 (local.get $record))
									(local.get $length)
								)
							)
							(then
								(call $fail (i32.const 10))
								(return)
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $names)
					)
				)
				(call $next)
			)
		)
		(local.set $record (call $data-record (global.get $segment-count)))
		;; Parenthesized headers identify active segments; strings or a closing delimiter identify passive data.
		(if
			(i32.or
				(i32.eq (global.get $kind) (i32.const 1))
				(i32.eq (global.get $kind) (i32.const 3))
			)
			(then
				;; A parenthesized memory selector precedes the offset; other openings belong to the initializer.
				(if (i32.eq (global.get $kind) (i32.const 1))
					(then
						(local.set $open (global.get $tok))
						(call $next)
						;; Consume only the explicit memory wrapper, replaying offset expressions unchanged.
						(if (call $is-word (i32.const 80) (i32.const 6))
							(then
								(call $next)
								(call $segment-target (local.get $record))
								(call $expect (i32.const 2))
							)
							;; Ordinary initializer parentheses must remain available to the constant-expression parser.
							(else
								(global.set $pos (local.get $open))
								(call $next)
							)
						)
					)
				)
				(call $segment-target (local.get $record))
				(local.set $offset (call $initializer))
				(local.set $reference (global.get $initializer-reference))
			)
			;; Passive segments retain bytes without requiring or writing a memory at instantiation.
			(else
				(local.set $passive (i32.const 1))
			)
		)
		(drop (call $data-segment (local.get $offset) (local.get $source)))
		;; Parsing failures must not publish mode/name fields or dereference a missing record.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(i32.store offset=28 (local.get $record) (local.get $reference))
		(i32.store offset=32 (local.get $record) (local.get $name))
		(i32.store offset=36 (local.get $record) (local.get $length))
		(i32.store offset=40 (local.get $record) (local.get $passive))
		(i32.store offset=44
			(local.get $record)
			(select (i32.load offset=8 (local.get $record)) (i32.const 0) (local.get $passive))
		)
	)

	;; Resolve memory.init/data.drop references once the entire data namespace has been parsed.
	(func $resolve-data
		(local $i i32)
		(local $record i32)
		(local $op i32)

		;; Finish after every normalized instruction has had its deferred data reference checked.
		(block $done
			;; References remain checked even in dead code and before instantiation writes.
			(loop $code
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $code-count)))
				(local.set $record
					(i32.add (global.get $code-base) (i32.mul (local.get $i) (i32.const 16)))
				)
				(local.set $op (i32.load (local.get $record)))
				;; Other opcodes retain their existing immediate metadata.
				(if
					(i32.or (i32.eq (local.get $op) (i32.const 189)) (i32.eq (local.get $op) (i32.const 190)))
					(then
						(global.set $tok (i32.load offset=8 (local.get $record)))
						(i32.store offset=4
							(local.get $record)
							(call $data-target
								(i32.load offset=4 (local.get $record))
								(i32.load offset=12 (local.get $record))
							)
						)
						(i32.store offset=12 (local.get $record) (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $code)
			)
		)
	)

	;; Validate one raw UTF-8 scalar inside a string and return its encoded byte count.
	(func $utf8-length
		(param $p i32)
		(param $end i32)
		(result i32)
		(local $c i32)
		(local $width i32)
		(local $v i32)
		(local $minimum i32)
		(local $i i32)

		(local.set $c (i32.load8_u (local.get $p)))
		;; ASCII bytes have already passed the lexer's control-byte checks.
		(if (i32.lt_u (local.get $c) (i32.const 128))
			(then
				(return (i32.const 1))
			)
		)
		;; Two-byte sequences exclude invalid overlong leading bytes C0 and C1.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 194))
				(i32.le_u (local.get $c) (i32.const 223))
			)
			(then
				(local.set $width (i32.const 2))
				(local.set $minimum (i32.const 128))
				(local.set $v (i32.and (local.get $c) (i32.const 31)))
			)
		)
		;; Three-byte sequences encode BMP scalars with a minimum value of 0x800.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 224))
				(i32.le_u (local.get $c) (i32.const 239))
			)
			(then
				(local.set $width (i32.const 3))
				(local.set $minimum (i32.const 2048))
				(local.set $v (i32.and (local.get $c) (i32.const 15)))
			)
		)
		;; Four-byte sequences may begin only with F0 through F4.
		(if
			(i32.and
				(i32.ge_u (local.get $c) (i32.const 240))
				(i32.le_u (local.get $c) (i32.const 244))
			)
			(then
				(local.set $width (i32.const 4))
				(local.set $minimum (i32.const 65536))
				(local.set $v (i32.and (local.get $c) (i32.const 7)))
			)
		)
		;; Reject invalid leading bytes and truncated encodings before reading continuation bytes.
		(if
			(i32.or
				(i32.eqz (local.get $width))
				(i32.gt_u (i32.add (local.get $p) (local.get $width)) (local.get $end))
			)
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(local.set $i (i32.const 1))
		;; Finish after all continuation bytes have contributed to the scalar.
		(block $done
			;; Each continuation must have the binary prefix 10.
			(loop $bytes
				(br_if $done (i32.eq (local.get $i) (local.get $width)))
				(local.set $c (i32.load8_u (i32.add (local.get $p) (local.get $i))))
				;; Reject stray ASCII or another leading byte inside the sequence.
				(if (i32.ne (i32.and (local.get $c) (i32.const 192)) (i32.const 128))
					(then
						(call $fail (i32.const 1))
						(return (i32.const 0))
					)
				)
				(local.set $v
					(i32.or (i32.shl (local.get $v) (i32.const 6)) (i32.and (local.get $c) (i32.const 63)))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $bytes)
			)
		)
		;; Reject overlong encodings, surrogates and values above the Unicode range.
		(if
			(i32.or
				(i32.lt_u (local.get $v) (local.get $minimum))
				(i32.or
					(i32.gt_u (local.get $v) (i32.const 1114111))
					(i32.and
						(i32.ge_u (local.get $v) (i32.const 55296))
						(i32.le_u (local.get $v) (i32.const 57343))
					)
				)
			)
			(then
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(local.get $width)
	)
