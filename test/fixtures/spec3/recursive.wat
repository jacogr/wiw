(module
 (rec
  (type $base (sub (struct (field (mut i32)) (field (ref null $base)))))
  (type $leaf (sub $base (struct (field (mut i32)) (field (ref null $base)) (field i32)))))
 (func (export "run") (result i32)
  (struct.get $base 0 (struct.new $leaf (i32.const 42) (ref.null $base) (i32.const 7))))
 (func (export "cast") (result i32)
  (ref.test (ref $leaf) (struct.new $leaf (i32.const 42) (ref.null $base) (i32.const 7)))))
