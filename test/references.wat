(module
	;; Export a numeric function to test opaque function-reference identity.
	(func (export "answer") (result i32) i32.const 42)
	;; Function nulls do not require a table.
	(func (export "nullFunc") (result funcref) ref.null func)
	;; External nulls retain the external reference type.
	(func (export "nullExtern") (result externref) ref.null extern)
	;; External identity preserves every opaque JavaScript value.
	(func (export "identity") (param externref) (result externref) local.get 0)
	;; Function identity preserves a live typed function or null.
	(func (export "functionIdentity") (param funcref) (result funcref) local.get 0)
	;; Null testing distinguishes null from undefined and all other external values.
	(func (export "isNull") (param externref) (result i32) local.get 0 ref.is_null)
	;; Function null testing accepts the other reference type.
	(func (export "functionIsNull") (param funcref) (result i32) local.get 0 ref.is_null)
	;; Typed select preserves the chosen external reference.
	(func (export "choose") (param externref externref i32) (result externref)
		(select (result externref) (local.get 0) (local.get 1) (local.get 2)))
	;; Typed numeric selection preserves bits through its existing runtime path.
	(func (export "chooseFloat") (param f64 f64 i32) (result f64)
		local.get 0 local.get 1 local.get 2 select (result f64))
	;; Declared reference locals begin as null.
	(func (export "localNull") (result i32) (local externref funcref)
		local.get 0 ref.is_null local.get 1 ref.is_null i32.add)
	(global $e (export "external") (mut externref) (ref.null extern))
	(global $f (export "function") (mut funcref) (ref.null func))
	;; A branch carries a reference using the block's exact result type.
	(func (export "branch") (param externref) (result externref)
		;; The branch publishes its reference at the result boundary.
		(block (result externref) local.get 0 br 0))
)
