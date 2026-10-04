(module
 (tag $e (param i32))
 (func (export "run") (param i32) (result i32)
  (block $caught (result i32)
   (try_table (catch $e $caught) (throw $e (local.get 0)))
   (i32.const 0)))
 (func (export "uncaught") (throw $e (i32.const 7))))
