(module
	(type $value (func (result i32)))
	;; Distinct results make copied references observable through indirect calls.
	(func $a (result i32) i32.const 10)
	;; Identify the second reference after overlap shifts.
	(func $b (result i32) i32.const 11)
	;; Identify the third reference after overlap shifts.
	(func $c (result i32) i32.const 12)
	;; Identify the fourth reference after overlap shifts.
	(func $d (result i32) i32.const 13)
	(elem (i32.const 0) $a $b $c $d)
	;; Observe the sole table through its optional default index.
	(func (export "size") (result i32) table.size)
	;; Preserve a forward table name until the module has been parsed.
	(func (export "namedSize") (result i32) (table.size $t))
	;; Copy stack operands in destination, source, length order.
	(func (export "copy") (param i32 i32 i32)
		local.get 0 local.get 1 local.get 2 table.copy)
	;; Explicit indices and folded operands use the same copy semantics.
	(func (export "namedCopy") (param i32 i32 i32)
		(table.copy $t $t (local.get 0) (local.get 1) (local.get 2)))
	;; Numeric targets resolve in the table namespace.
	(func (export "indexedSize") (result i32) table.size 0)
	;; Observe each slot's function identity, or its null trap.
	(func (export "peek") (param i32) (result i32)
		local.get 0 call_indirect (type $value))
	(table $t (export "table") 8 8 funcref)
)
