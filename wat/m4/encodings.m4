m4_dnl Emit one tab per authoring indentation level, without changing generated instructions.
m4_define(<!M4_WAT_INDENT!>,<!m4_ifelse($1,<!0!>,<!!>,<!	M4_WAT_INDENT(m4_decr($1))!>)!>)m4_dnl
m4_dnl Decode an ASCII hex byte in local $1 into local $2, or -1; $3 is the WAT nesting depth.
m4_dnl Callers supply local names without $, so helpers and hot loops share the same rules.
m4_define(<!M4_HEX_DIGIT!>,<!
m4_pushdef(<!M4_HEX_INDENT!>,M4_WAT_INDENT($3))m4_dnl
M4_HEX_INDENT()(local.set $$2 (i32.sub (local.get $$1) (i32.const M4_ASCII_ZERO)))
M4_HEX_INDENT();; Decimal digits need no case folding or alphabetic range check.
M4_HEX_INDENT()(if (i32.gt_u (local.get $$2) (i32.const M4_DECIMAL_LAST_DIGIT))
M4_HEX_INDENT()	(then
M4_HEX_INDENT()		(local.set $$2
M4_HEX_INDENT()			(i32.sub (i32.or (local.get $$1) (i32.const M4_ASCII_CASE_BIT)) (i32.const M4_ASCII_LOWER_A)))
M4_HEX_INDENT()		;; Folded A-F/a-f map to ten through fifteen; every other i32 value is invalid.
M4_HEX_INDENT()		(if (i32.le_u (local.get $$2) (i32.const M4_HEX_LAST_LETTER))
M4_HEX_INDENT()			(then (local.set $$2 (i32.add (local.get $$2) (i32.const M4_DECIMAL_RADIX))))
M4_HEX_INDENT()			;; Invalid bytes keep the sentinel used by escape and literal decoders.
M4_HEX_INDENT()			(else (local.set $$2 (i32.const -1)))
M4_HEX_INDENT()		)
M4_HEX_INDENT()	)
M4_HEX_INDENT())
m4_popdef(<!M4_HEX_INDENT!>)!>)m4_dnl
