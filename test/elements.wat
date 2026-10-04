(module
	(type $value (func (result i32)))
	(table $t (export "table") 8 funcref)
	(elem $active (table $t) (i32.const 0) func $f0 $f1)
	(elem $passive funcref (ref.func $f1) (item ref.null func) (item (ref.func $f0)))
	(elem $declared declare func $f2)
	(global (export "globalReference") funcref (ref.func $f2))
	;; A forward active/passive reference identifies the first function.
	(func $f0 (export "f0") (result i32) i32.const 10)
	;; A second callable identity makes segment order observable.
	(func $f1 (result i32) i32.const 20)
	;; A declarative segment declares an otherwise unexported function.
	(func $f2 (result i32) i32.const 30)
	;; Read a nullable entry using the explicit table name.
	(func (export "get") (param i32) (result funcref) local.get 0 table.get $t)
	;; Write a typed reference while retaining the table's null representation.
	(func (export "set") (param i32 funcref) local.get 0 local.get 1 table.set $t)
	;; Initialize from the passive expression list without consuming its entries.
	(func (export "init") (param i32 i32 i32)
		(table.init $t $passive (local.get 0) (local.get 1) (local.get 2)))
	;; The one-index spelling selects table zero and the named passive segment.
	(func (export "defaultInit") (param i32 i32 i32)
		local.get 0 local.get 1 local.get 2 table.init $passive)
	;; Active segments are already dropped after instantiation.
	(func (export "activeInit") (param i32 i32 i32)
		local.get 0 local.get 1 local.get 2 table.init $active)
	;; Declarative segments establish declarations but have no runtime entries.
	(func (export "declaredInit") (param i32 i32 i32)
		local.get 0 local.get 1 local.get 2 table.init $declared)
	;; Drop may be repeated, including for active and declarative segments.
	(func (export "drop") elem.drop $passive elem.drop $active elem.drop $declared)
	;; Produce a declared function value without reading any table entry.
	(func (export "reference") (result funcref) ref.func $f2)
	;; Indirect calls resolve an explicit table and its structural type separately.
	(func (export "call") (param i32) (result i32)
		local.get 0 call_indirect $t (type $value))
)
