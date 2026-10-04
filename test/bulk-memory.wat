(module
	(memory (export "memory") 1 2)
	(data $active (i32.const 0) "abcdefghijklmnopqrstuvwx")
	(data $passive "0123456789abcdef")
	;; Copy bytes with overlap-safe semantics.
	(func (export "copy") (param i32 i32 i32)
		local.get 0
		local.get 1
		local.get 2
		memory.copy
	)
	;; Fill a checked range with the low byte of the supplied value.
	(func (export "fill") (param i32 i32 i32)
		local.get 0
		local.get 1
		local.get 2
		memory.fill
	)
	;; Initialize a range from the passive segment without consuming its bytes.
	(func (export "init") (param i32 i32 i32)
		local.get 0
		local.get 1
		local.get 2
		memory.init $passive
	)
	;; Active segments are already dropped once instantiation has applied their bytes.
	(func (export "initActive") (param i32 i32 i32)
		local.get 0
		local.get 1
		local.get 2
		memory.init $active
	)
	;; Drop passive bytes idempotently for this instance.
	(func (export "drop")
		data.drop $passive
	)
	;; Read a byte to verify bulk behavior through interpreted host adapters.
	(func (export "peek") (param i32) (result i32)
		local.get 0
		i32.load8_u
	)
)
