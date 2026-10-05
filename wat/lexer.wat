	;; Token kinds: EOF=0, '('=1, ')'=2, atom=3, string=4.
	;; Read the current source byte without advancing; return 0 at end of input.
	(func $peek
		(result i32)

		;; Read memory only while the source cursor is inside the input range.
		(if (result i32) (i32.lt_u (global.get $pos) (global.get $end))
			(then
				(i32.load8_u (global.get $pos))
			)
			;; End of input has no byte to read; return the sentinel instead.
			(else
				(i32.const 0)
			)
		)
	)

	;; Move the source cursor forward by one byte; callers ensure a byte is available.
	(func $advance
		(global.set $pos (i32.add (global.get $pos) (i32.const 1)))
	)

	;; Check whether the next two source bytes match a and b without consuming them.
	(func $pair
		(param $a i32)
		(param $b i32)
		(result i32)

		;; Check both bytes only when the second byte is still inside the source.
		(if (result i32) (i32.lt_u (i32.add (global.get $pos) (i32.const 1)) (global.get $end))
			(then
				(i32.and
					(i32.eq (call $peek) (local.get $a))
					(i32.eq (i32.load8_u (i32.add (global.get $pos) (i32.const 1))) (local.get $b))
				)
			)
			;; Fewer than two remaining bytes cannot match a pair.
			(else
				(i32.const 0)
			)
		)
	)

	;; Recognize the four WAT whitespace bytes: space, tab, line feed and carriage return.
	(func $space
		(param $c i32)
		(result i32)

		(i32.or
			(i32.eq (local.get $c) (i32.const 32))
			(i32.or
				(i32.eq (local.get $c) (i32.const 9))
				(i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13)))
			)
		)
	)

	;; Consume whitespace and comments, then expose the next token through kind, tok and len.
	;; Leave kind as EOF at end of input; report lexical failures through the shared status.
	(func $next
		(local $c i32)
		(local $depth i32)
		(local $name i32)

		(global.set $kind (i32.const 0))
		(global.set $len (i32.const 0))
		;; Leave this region once the cursor reaches a token or the end of input.
		(block $skip-done
			;; Keep skipping whitespace and comments before classifying a token.
			(loop $skip
				(global.set $tok (global.get $pos))
				(br_if $skip-done (i32.ge_u (global.get $pos) (global.get $end)))
				;; Consume one whitespace byte and resume skipping.
				(if (call $space (call $peek))
					(then
						(call $advance)
						(br $skip)
					)
				)
				;; An annotation is trivia even when it occurs between an opening delimiter and its keyword.
				(if (call $pair (i32.const 40) (i32.const 64))
					(then
						(call $skip-annotation)
						;; A malformed annotation stops scanning at its first failure.
						(if (global.get $error)
							(then
								(return)
							)
						)
						(br $skip)
					)
				)
				;; A double semicolon starts a comment that runs to the line ending.
				(if (call $pair (i32.const 59) (i32.const 59))
					(then
						;; Discard comment bytes until newline or EOF, then resume skipping.
						(loop $line
							(br_if $skip (i32.ge_u (global.get $pos) (global.get $end)))
							(br_if $skip
								(i32.or (i32.eq (call $peek) (i32.const 10)) (i32.eq (call $peek) (i32.const 13)))
							)
							(call $advance)
							(br $line)
						)
					)
				)
				;; An opening parenthesis followed by a semicolon starts a nested block comment.
				(if (call $pair (i32.const 40) (i32.const 59))
					(then
						(call $advance)
						(call $advance)
						(local.set $depth (i32.const 1))
						;; Track nested comment delimiters until the outermost comment closes.
						(loop $comment
							;; EOF before the outer comment closes is a syntax error.
							(if (i32.ge_u (global.get $pos) (global.get $end))
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
									(return)
								)
							)
							;; A nested opening delimiter increases the number of comments still to close.
							(if (call $pair (i32.const 40) (i32.const 59))
								(then
									(local.set $depth (i32.add (local.get $depth) (i32.const 1)))
									(call $advance)
									(call $advance)
									(br $comment)
								)
							)
							;; A closing delimiter removes one nesting level; zero resumes token scanning.
							(if (call $pair (i32.const 59) (i32.const 41))
								(then
									(local.set $depth (i32.sub (local.get $depth) (i32.const 1)))
									(call $advance)
									(call $advance)
									(br_if $skip (i32.eqz (local.get $depth)))
									(br $comment)
								)
							)
							(call $advance)
							(br $comment)
						)
					)
				)
				(br $skip-done)
			)
		)
		(global.set $tok (global.get $pos))
		;; After skipping, EOF leaves the token kind at its initial EOF value.
		(if (i32.ge_u (global.get $pos) (global.get $end))
			(then
				(return)
			)
		)
		;; Quoted identifiers decode into the same dollar-prefixed byte namespace as ordinary identifiers.
		(if (call $pair (i32.const 36) (i32.const 34))
			(then
				(call $advance)
				(call $quoted-token)
				;; Quoted identifiers need a token boundary before the following atom.
				(local.set $c (call $peek))
				;; Adjacent non-delimiter bytes cannot extend a completed quoted identifier.
				(if
					(i32.and
						(i32.gt_u (local.get $c) (i32.const 32))
						(i32.and
							(i32.ne (local.get $c) (i32.const 40))
							(i32.and (i32.ne (local.get $c) (i32.const 41)) (i32.ne (local.get $c) (i32.const 59)))
						)
					)
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
					)
				)
				(local.set $name (i32.add (global.get $data-base) (global.get $data-count)))
				(call $data-byte (i32.const 36))
				(drop (call $export-name (global.get $tok) (global.get $len)))
				;; A quoted identifier must decode to at least one byte after its dollar prefix.
				(if (i32.eqz (global.get $decoded-name-length))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
					)
				)
				(global.set $tok (local.get $name))
				(global.set $len (i32.add (global.get $decoded-name-length) (i32.const 1)))
				(global.set $kind (i32.const 3))
				(return)
			)
		)
		(local.set $c (call $peek))
		;; An opening parenthesis is a complete one-byte token.
		(if (i32.eq (local.get $c) (i32.const 40))
			(then
				(global.set $kind (i32.const 1))
				(call $advance)
				(return)
			)
		)
		;; A closing parenthesis is a complete one-byte token.
		(if (i32.eq (local.get $c) (i32.const 41))
			(then
				(global.set $kind (i32.const 2))
				(call $advance)
				(return)
			)
		)
		;; An opening quote starts a string; exclude both quotes from the token span.
		(if (i32.eq (local.get $c) (i32.const 34))
			(then
				(call $quoted-token)
				(return)
			)
		)
		(global.set $kind (i32.const 3))
		;; Exit here at an atom boundary, leaving the delimiter for the next token.
		(block $atom-done
			;; Scan an atom until EOF, whitespace, a parenthesis or a line comment.
			(loop $atom
				(br_if $atom-done (i32.ge_u (global.get $pos) (global.get $end)))
				(local.set $c (call $peek))
				(br_if $atom-done (call $space (local.get $c)))
				(br_if $atom-done
					(i32.or (i32.eq (local.get $c) (i32.const 40)) (i32.eq (local.get $c) (i32.const 41)))
				)
				(br_if $atom-done (call $pair (i32.const 59) (i32.const 59)))
				;; A quote or NUL inside an atom is invalid syntax.
				(if (i32.or (i32.eq (local.get $c) (i32.const 34)) (i32.eqz (local.get $c)))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
						(return)
					)
				)
				(call $advance)
				(br $atom)
			)
		)
		(global.set $len (i32.sub (global.get $pos) (global.get $tok)))
	)

	;; Consume a quoted token while preserving escaped delimiters and rejecting literal controls.
	(func $quoted-token
		(global.set $kind (i32.const 4))
		(call $advance)
		(global.set $tok (global.get $pos))
		;; Scan the string contents until a closing quote or a lexical failure.
		(loop $string
			;; EOF inside a quoted string means its closing quote is missing.
			(if (i32.ge_u (global.get $pos) (global.get $end))
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			;; Finish the string span and consume its closing quote.
			(if (i32.eq (call $peek) (i32.const 34))
				(then
					(global.set $len (i32.sub (global.get $pos) (global.get $tok)))
					(call $advance)
					;; Adjacent strings require separating whitespace or a comment.
					(if (i32.eq (call $peek) (i32.const 34))
						(then
							(call $fail (i32.const M4_ERR_SYNTAX))
						)
					)
					(return)
				)
			)
			;; Escaped quotes are content; leave escape decoding to the owning grammar.
			(if (i32.eq (call $peek) (i32.const 92))
				(then
					(call $advance)
					;; A backslash requires a following non-control source byte.
					(if
						(i32.or
							(i32.ge_u (global.get $pos) (global.get $end))
							(i32.or (i32.lt_u (call $peek) (i32.const 32)) (i32.eq (call $peek) (i32.const 127)))
						)
						(then
							(call $fail (i32.const M4_ERR_SYNTAX))
							(return)
						)
					)
					(call $advance)
					(br $string)
				)
			)
			;; Literal control bytes are forbidden, while UTF-8 data text is allowed.
			(if
				(i32.or (i32.lt_u (call $peek) (i32.const 32)) (i32.eq (call $peek) (i32.const 127)))
				(then
					(call $fail (i32.const M4_ERR_UNSUPPORTED))
					(return)
				)
			)
			(call $advance)
			(br $string)
		)
	)

	;; Skip one balanced annotation, validating names, strings, comments and permitted source bytes.
	(func $skip-annotation
		(local $depth i32)
		(local $comments i32)
		(local $c i32)

		(call $advance)
		(call $advance)
		;; Annotation names cannot be empty or separated from their at-sign by trivia.
		(if
			(i32.or
				(call $space (call $peek))
				(i32.or (i32.eq (call $peek) (i32.const 40)) (i32.eq (call $peek) (i32.const 41)))
			)
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return)
			)
		)
		;; Quoted annotation names obey the same UTF-8 and escape rules as string names.
		(if (i32.eq (call $peek) (i32.const 34))
			(then
				(call $quoted-token)
				(drop (call $export-name (global.get $tok) (global.get $len)))
				;; Empty decoded annotation names are malformed.
				(if (i32.eqz (global.get $decoded-name-length))
					(then
						(call $fail (i32.const M4_ERR_SYNTAX))
					)
				)
			)
		)
		(local.set $depth (i32.const 1))
		;; Balanced parentheses delimit content; comments and strings hide their own delimiters.
		(loop $content
			;; EOF or a prior lexical failure cannot complete the annotation.
			(if (i32.or (global.get $error) (i32.ge_u (global.get $pos) (global.get $end)))
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			;; Line comments ignore all content through the next newline.
			(if (call $pair (i32.const 59) (i32.const 59))
				(then
					;; End of line or EOF finishes this comment.
					(block $line-end
						;; Comment bytes do not affect annotation nesting.
						(loop $line
							(br_if $line-end
								(i32.or
									(i32.eq (call $peek) (i32.const 10))
									(i32.ge_u (global.get $pos) (global.get $end))
								)
							)
							(call $advance)
							(br $line)
						)
					)
					(br $content)
				)
			)
			;; Block comments can nest independently of annotation parentheses.
			(if (call $pair (i32.const 40) (i32.const 59))
				(then
					(local.set $comments (i32.const 1))
					(call $advance)
					(call $advance)
					;; A closing comment at depth zero returns to annotation content.
					(block $comment-end
						;; Consume nested comment delimiters without changing annotation depth.
						(loop $comment
							;; An unfinished block comment is malformed.
							(if (i32.ge_u (global.get $pos) (global.get $end))
								(then
									(call $fail (i32.const M4_ERR_SYNTAX))
									(return)
								)
							)
							;; Each opening delimiter creates another comment level.
							(if (call $pair (i32.const 40) (i32.const 59))
								(then
									(local.set $comments (i32.add (local.get $comments) (i32.const 1)))
									(call $advance)
									(call $advance)
									(br $comment)
								)
							)
							;; Each closing delimiter completes its current comment level.
							(if (call $pair (i32.const 59) (i32.const 41))
								(then
									(local.set $comments (i32.sub (local.get $comments) (i32.const 1)))
									(call $advance)
									(call $advance)
									(br_if $comment-end (i32.eqz (local.get $comments)))
									(br $comment)
								)
							)
							(call $advance)
							(br $comment)
						)
					)
					(br $content)
				)
			)
			(local.set $c (call $peek))
			;; Strings may contain otherwise significant delimiters and escaped arbitrary bytes.
			(if (i32.eq (local.get $c) (i32.const 34))
				(then
					(call $quoted-token)
					(call $decode-data)
					(br $content)
				)
			)
			;; Bare annotation content is ASCII with only the four permitted whitespace controls.
			(if
				(i32.or
					(i32.ge_u (local.get $c) (i32.const 127))
					(i32.and (i32.lt_u (local.get $c) (i32.const 32)) (i32.eqz (call $space (local.get $c))))
				)
				(then
					(call $fail (i32.const M4_ERR_SYNTAX))
					(return)
				)
			)
			;; Opening content parentheses add one nesting level.
			(if (i32.eq (local.get $c) (i32.const 40))
				(then
					(local.set $depth (i32.add (local.get $depth) (i32.const 1)))
				)
			)
			;; Closing the outermost parenthesis finishes the annotation.
			(if (i32.eq (local.get $c) (i32.const 41))
				(then
					(local.set $depth (i32.sub (local.get $depth) (i32.const 1)))
					(call $advance)
					;; The outer closing parenthesis ends the annotation.
					(if (i32.eqz (local.get $depth))
						(then
							(return)
						)
					)
					(br $content)
				)
			)
			(call $advance)
			(br $content)
		)
	)
