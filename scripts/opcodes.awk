# Emit keyword matching, stack effects and arithmetic from the opcode table.
# Generated WAT remains readable and follows the same comment convention.
/^#/ || NF == 0 { next }
{
  count++
  id[count] = $1
  name[count] = $2
  inputs[count] = $3
  outputs[count] = $4
  operation[count] = $5
  inputtype[count] = $6
  outputtype[count] = $7
  binary[count] = $8
  if ($1 != count || count > 256) { invalid = 1; exit 1 }
}
function decoded(type, arg) {
  if (type == 1) return "(i32.wrap_i64 (local.get $" arg "))"
  if (type == 3) return "(f32.reinterpret_i32 (i32.wrap_i64 (local.get $" arg ")))"
  if (type == 4) return "(f64.reinterpret_i64 (local.get $" arg "))"
  return "(local.get $" arg ")"
}
END {
  if (invalid) exit 1
  print "\t;; Opcode keyword bytes occupy reserved memory below the host source buffers."
  offset = 128
  print "\t(data (i32.const 128)"
  for (i = 1; i <= count; i++) {
    address[i] = offset
    printf "\t\t\"%s\"\n", name[i]
    offset += length(name[i])
  }
  print "\t)"
  if (offset > 3072) exit 1
  print "\n\t;; Each opcode has a four-byte record: operand/result counts, then their scalar types."
  print "\t(data (i32.const 3076)"
  for (i = 1; i <= count; i++) {
    printf "\t\t\"\\%02x\\%02x\\%02x\\%02x\"\n", inputs[i], outputs[i], inputtype[i], outputtype[i]
  }
  print "\t)"
  print "\n\t;; Resolve the current atom to an opcode; zero means unsupported."
  print "\t(func $opcode\n\t\t(result i32)\n"
  for (i = 1; i <= count; i++) {
    printf "\t\t;; Recognize %s by its length and keyword bytes.\n", name[i]
    printf "\t\t(if (i32.and (i32.eq (global.get $len) (i32.const %d))\n", length(name[i])
    printf "\t\t\t(call $equal (global.get $tok) (i32.const %d) (i32.const %d)))\n", address[i], length(name[i])
    printf "\t\t\t(then\n\t\t\t\t(return (i32.const %d))\n\t\t\t)\n\t\t)\n", id[i]
  }
  print "\t\t(i32.const 0)\n\t)"
  print "\n\t;; Decode a wire opcode to its WAT mnemonic without compiling guest instructions."
  print "\t(func $binary-opname\n\t\t(param $byte i32)\n\t\t(result i32)"
  for (i = 1; i <= count; i++) {
    printf "\t\t;; Emit the MVP mnemonic for binary opcode %d (%s).\n", binary[i], name[i]
    printf "\t\t(if (i32.eq (local.get $byte) (i32.const %d))\n", binary[i]
    printf "\t\t\t(then (call $binary-copy (i32.const %d) (i32.const %d)) (return (i32.const 1)))\n\t\t)\n", address[i], length(name[i])
  }
  print "\t\t(i32.const 0)\n\t)"
  print "\n\t;; Return the number of operands consumed by a known opcode."
  print "\t(func $inputs\n\t\t(param $op i32)\n\t\t(result i32)\n"
  print "\t\t(i32.load8_u (i32.add (i32.const 3072) (i32.mul (local.get $op) (i32.const 4))))\n\t)"
  print "\n\t;; Return the number of results produced by a known opcode."
  print "\t(func $outputs\n\t\t(param $op i32)\n\t\t(result i32)\n"
  print "\t\t(i32.load8_u (i32.add (i32.const 3073) (i32.mul (local.get $op) (i32.const 4))))\n\t)"
  print "\n\t;; Apply a unary or binary integer operation after the runtime checks trap conditions."
  print "\t(func $apply\n\t\t(param $op i32)\n\t\t(param $a i32)\n\t\t(param $b i32)\n\t\t(result i32)\n"
  for (i = 1; i <= count; i++) {
    if (i > 60 || operation[i] == "const" || operation[i] == "drop" || operation[i] == "nop" || operation[i] == "local" || operation[i] == "call" || operation[i] == "control" || operation[i] == "resource") continue
    printf "\t\t;; Execute %s using operands in source stack order.\n", name[i]
    printf "\t\t(if (i32.eq (local.get $op) (i32.const %d))\n", id[i]
    printf "\t\t\t(then\n\t\t\t\t(return (%s (local.get $a)", operation[i]
    if (inputs[i] == 2) printf " (local.get $b)"
    print "))\n\t\t\t)\n\t\t)"
  }
  print "\t\t(i32.const 0)\n\t)"

  print "\n\t;; Return an opcode's scalar operand type; stores use their address type for the second pop."
  print "\t(func $operand-type\n\t\t(param $op i32)\n\t\t(param $position i32)\n\t\t(result i32)"
  print "\t\t;; Stores consume a typed value followed by an i32 address."
  print "\t\t(if (i32.and (call $store-op (local.get $op)) (local.get $position))\n\t\t\t(then (return (i32.const 1)))\n\t\t)"
  print "\t\t(i32.load8_u (i32.add (i32.const 3074) (i32.mul (local.get $op) (i32.const 4))))\n\t)"
  print "\n\t;; Return an opcode's declared scalar result type for typed validation."
  print "\t(func $output-type\n\t\t(param $op i32)\n\t\t(result i32)"
  print "\t\t(i32.load8_u (i32.add (i32.const 3075) (i32.mul (local.get $op) (i32.const 4))))\n\t)"
  print "\n\t;; Apply an i64 numeric operation or width conversion after runtime trap checks."
  print "\t(func $apply64\n\t\t(param $op i32)\n\t\t(param $a i64)\n\t\t(param $b i64)\n\t\t(result i64)"
  for (i = 62; i <= 93; i++) {
    printf "\t\t;; Execute %s with full-width integer operands.\n", name[i]
    printf "\t\t(if (i32.eq (local.get $op) (i32.const %d))\n\t\t\t(then\n\t\t\t\t(return ", i
    if (i >= 77 && i <= 87) printf "(i64.extend_i32_u "
    if (i == 91) printf "(i64.extend_i32_s (i32.wrap_i64 (local.get $a)))"
    else if (i == 92 || i == 93) printf "(%s (i32.wrap_i64 (local.get $a)))", name[i]
    else {
      printf "(%s (local.get $a)", name[i]
      if (inputs[i] == 2) printf " (local.get $b)"
      printf ")"
    }
    if (i >= 77 && i <= 87) printf ")"
    print ")\n\t\t\t)\n\t\t)"
  }
  print "\t\t(i64.const 0)\n\t)"
  print "\n\t;; Recognize stores whose address is popped after their typed value."
  print "\t(func $store-op\n\t\t(param $op i32)\n\t\t(result i32)"
  print "\t\t(i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 58)) (i32.le_u (local.get $op) (i32.const 60)))"
  print "\t\t\t(i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 101)) (i32.le_u (local.get $op) (i32.const 104)))"
  print "\t\t\t\t(i32.or (i32.eq (local.get $op) (i32.const 149)) (i32.eq (local.get $op) (i32.const 151)))))"
  print "\t)"
  print "\n\t;; Recognize all scalar loads and stores for memarg parsing and resource dispatch."
  print "\t(func $memory-op\n\t\t(param $op i32)\n\t\t(result i32)"
  print "\t\t(i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 53)) (i32.le_u (local.get $op) (i32.const 60)))"
  print "\t\t\t(i32.or (i32.and (i32.ge_u (local.get $op) (i32.const 94)) (i32.le_u (local.get $op) (i32.const 104)))"
  print "\t\t\t\t(i32.and (i32.ge_u (local.get $op) (i32.const 148)) (i32.le_u (local.get $op) (i32.const 151)))))"
  print "\t)"
  print "\n\t;; Decode IEEE bit slots, execute floating-point arithmetic or conversions, and encode the result."
  print "\t(func $float-apply\n\t\t(param $op i32)\n\t\t(param $a i64)\n\t\t(param $b i64)\n\t\t(result i64)"
  for (i = 107; i <= count; i++) {
    if (operation[i] != "float" && operation[i] != "floatconvert") continue
    printf "\t\t;; Execute %s with the declared input and result types.\n", name[i]
    printf "\t\t(if (i32.eq (local.get $op) (i32.const %d))\n\t\t\t(then\n", i
    if (i >= 152 && i <= 159) {
      print "\t\t\t\t;; Reject NaN and overflow before a native integer conversion can trap."
      print "\t\t\t\t(if (call $float-trunc-check (local.get $op) (local.get $a))\n\t\t\t\t\t(then\n\t\t\t\t\t\t(return (i64.const 0))\n\t\t\t\t\t)\n\t\t\t\t)"
    }
    expr = "(" name[i] " " decoded(inputtype[i], "a")
    if (inputs[i] == 2) expr = expr " " decoded(inputtype[i], "b")
    expr = expr ")"
    if (outputtype[i] == 1) expr = "(i64.extend_i32_s " expr ")"
    if (outputtype[i] == 3) expr = "(i64.extend_i32_u (i32.reinterpret_f32 " expr "))"
    if (outputtype[i] == 4) expr = "(i64.reinterpret_f64 " expr ")"
    print "\t\t\t\t(return " expr ")\n\t\t\t)\n\t\t)"
  }
  print "\t\t(i64.const 0)\n\t)"

}
