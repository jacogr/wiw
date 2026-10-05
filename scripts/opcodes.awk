# Emit keyword matching, stack effects and arithmetic from the opcode table.
# Generated WAT remains readable and follows the same comment convention.
/^#/ || NF == 0 { next }
{
  count++
  id[count] = $1
  name[count] = $2
  if (length($2) > longest) longest = length($2)
  inputs[count] = $3
  outputs[count] = $4
  operation[count] = $5
  inputtype[count] = $6
  outputtype[count] = $7
  binary[count] = $8
  secondtype[count] = NF >= 9 ? $9 : $6
  if ($1 != count || count > 512 || $3 > 15 || $4 > 15 || $6 > 15 || $7 > 15) { invalid = 1; exit 1 }
}
function decoded(type, arg) {
  if (type == 1) return "(i32.wrap_i64 (local.get $" arg "))"
  if (type == 3) return "(f32.reinterpret_i32 (i32.wrap_i64 (local.get $" arg ")))"
  if (type == 4) return "(f64.reinterpret_i64 (local.get $" arg "))"
  return "(local.get $" arg ")"
}
# Mnemonics contain only these ASCII bytes; pack words in Wasm's little-endian order.
function mnemonic_byte(c, n) {
  if (c == " ") return 32
  n = index("abcdefghijklmnopqrstuvwxyz0123456789._", c)
  return n <= 26 ? n + 96 : (n <= 36 ? n + 21 : (n == 37 ? 46 : 95))
}
function mnemonic_word(text, start, width, n, j, scale) {
  n = 0
  scale = 1
  for (j = 0; j < width; j++) {
    n += mnemonic_byte(substr(text, start + j, 1)) * scale
    scale *= 256
  }
  return n
}
# Compare complete suffix words, then a halfword/byte tail, after its length is known.
function mnemonic_suffix(text, start, expr, term, width, j) {
  expr = ""
  for (j = start; j <= length(text); j += width) {
    width = length(text) - j + 1
    width = width >= 4 ? 4 : (width >= 2 ? 2 : 1)
    term = "(i32.eq (i32.load" (width == 4 ? "" : (width == 2 ? "16_u" : "8_u")) " offset=" (j - 1) " (global.get $tok)) (i32.const " mnemonic_word(text, j, width) "))"
    expr = expr == "" ? term : "(i32.and " expr " " term ")"
  }
  return expr
}
# Runtime families are exclusive; zero retains general numeric/resource execution.
# The packed route table fits between the scalar effects and reserved keywords.
function runtime_route(i) {
  # 1: scalar constants, locals and simple stack instructions.
  if (operation[i] == "const" || operation[i] == "const64" ||
      operation[i] == "floatconst" || operation[i] == "local" ||
      operation[i] == "drop" || operation[i] == "nop") return 1
  # 2: integer operations whose validated scalar result cannot trap or grow the stack.
  if ((i >= 2 && i <= 4) || (i >= 9 && i <= 30) ||
      (i >= 62 && i <= 64) || (i >= 69 && i <= 93) ||
      (i >= 174 && i <= 178)) return 2
  # 3/4: structured scope markers, and raw global/function reference reads.
  if ((i >= 37 && i <= 41) || i == 495) return 3
  if (i == 49 || i == 195) return 4
  # 5: all direct, indirect and reference calls, including their tail variants.
  if (operation[i] == "call" || operation[i] == "indirect" || i == 461 || i == 462) return 5
  # 6 through 12: traps, returns, exceptions, specialized branches and select.
  if (i == 45) return 6
  if (i == 44) return 7
  if (i == 496 || i == 497) return 8
  if (i == 493 || i == 494) return 9
  if (i == 463 || i == 464) return 10
  if (i == 42 || i == 43 || i == 46) return 11
  if (i == 47) return 12
  # 13/14: variable-arity aggregates, and table selection before general execution.
  if (i >= 473 && i <= 492) return 13
  if (i == 191 || i == 192 || (i >= 197 && i <= 201)) return 14
  # 15: select canonical memory before scalar, bulk or vector access checks.
  if ((i >= 416 && i <= 437) || (i >= 51 && i <= 60) ||
      (i >= 94 && i <= 104) || (i >= 148 && i <= 151) ||
      (i >= 187 && i <= 189)) return 15
  return 0
}

# Group extended opcodes by their complete effect and select a group with one branch.
# Scalar opcodes keep their existing packed table; unknown opcodes reach the caller's fallback.
function effect_dispatch(field, i, key, g, groups, tabs, expr, effect_group, effect_key, effect_id, effect_pair) {
  groups = 0
  for (i = 203; i <= count; i++) {
    key = field == "inputs" ? inputs[i] : (field == "outputs" ? outputs[i] : (field == "output-type" ? outputtype[i] : inputtype[i] ":" secondtype[i]))
    if (!((field SUBSEP key) in effect_group)) {
      effect_group[field, key] = groups
      effect_key[field, groups++] = key
    }
    effect_id[i] = effect_group[field, key]
  }
  tabs = "\t\t"
  print tabs ";; Unknown extended opcodes retain the existing fallback below."
  print tabs "(block $effect-default"
  tabs = tabs "\t"
  for (g = 0; g < groups; g++) {
    print tabs ";; Exit this label to return the " field " group " effect_key[field, g] "."
    print tabs "(block $effect-" g
    tabs = tabs "\t"
  }
  print tabs ";; Each validated extended opcode selects its complete declared effect."
  print tabs "(br_table"
  for (i = 203; i <= count; i++) print tabs "\t$effect-" effect_id[i] " ;; " name[i]
  print tabs "\t$effect-default"
  print tabs "\t(i32.sub (local.get $op) (i32.const 203))"
  print tabs ")"
  for (g = groups - 1; g >= 0; g--) {
    tabs = substr(tabs, 1, length(tabs) - 1)
    print tabs ")"
    key = effect_key[field, g]
    if (field == "operand-type") {
      split(key, effect_pair, ":")
      expr = effect_pair[1] == effect_pair[2] ? "(i32.const " effect_pair[1] ")" : "(select (i32.const " effect_pair[2] ") (i32.const " effect_pair[1] ") (local.get $position))"
    } else expr = "(i32.const " key ")"
    print tabs "(return " expr ")"
  }
  print "\t\t)"
}

# Search ordered wire IDs with bounded depth; holes still require an exact leaf match.
function binary_dispatch(low, high, tabs, middle, code, i, text, j, width, entry) {
  if (high - low < 16) {
    for (entry = low; entry <= high; entry++) {
      code = wire_order[entry]
      i = wire_id[code]
      printf "%s;; Emit %s only for its exact wire ID.\n", tabs, name[i]
      printf "%s(if (i32.eq (local.get $byte) (i32.const %d))\n%s\t(then\n", tabs, code, tabs
      if (i <= 202) {
        printf "%s\t\t(call $binary-copy (i32.const %d) (i32.const %d))\n", tabs, address[i], length(name[i])
      } else {
        text = name[i] " "
        for (j = 1; j <= length(text); j += width) {
          width = length(text) - j + 1
          width = width >= 4 ? 4 : (width >= 2 ? 2 : 1)
          printf "%s\t\t(call $binary-word (i32.const %d) (i32.const %d))\n", tabs, mnemonic_word(text, j, width), width
        }
      }
      printf "%s\t\t(return (i32.const 1))\n%s\t)\n%s)\n", tabs, tabs, tabs
    }
    return
  }
  middle = int((low + high) / 2)
  printf "%s;; Search wire IDs at or below %d in the lower half.\n", tabs, wire_order[middle]
  printf "%s(if (i32.le_u (local.get $byte) (i32.const %d))\n%s\t(then\n", tabs, wire_order[middle], tabs
  binary_dispatch(low, middle, tabs "\t\t")
  printf "%s\t)\n%s\t;; Larger wire IDs search the upper half.\n%s\t(else\n", tabs, tabs, tabs
  binary_dispatch(middle + 1, high, tabs "\t\t")
  printf "%s\t)\n%s)\n", tabs, tabs
}

END {
  if (invalid) exit 1
  print "\t;; Opcode keyword bytes occupy reserved memory below the host source buffers."
  offset = 128
  print "\t(data (i32.const 128)"
  for (i = 1; i <= count && i <= 202; i++) {
    address[i] = offset
    printf "\t\t\"%s\"\n", name[i]
    offset += length(name[i])
  }
  print "\t)"
  if (offset > 3072) exit 1
  print "\n\t;; Each opcode packs operand/result counts and types into two pairs of four-bit fields."
  print "\t(data (i32.const 3074)"
  for (i = 1; i <= count && i <= 202; i++) {
    printf "\t\t\"\\%02x\\%02x\"\n", inputs[i] * 16 + outputs[i], inputtype[i] * 16 + outputtype[i]
  }
  print "\t)"
  if (3480 + int(count / 2) + 1 > 3840) exit 1
  print "\n\t;; Runtime routes use one nibble per opcode; opcode zero selects the general path."
  print "\t(data (i32.const 3480)"
  for (i = 0; i <= count; i += 2) {
    low = i ? runtime_route(i) : 0
    high = i + 1 <= count ? runtime_route(i + 1) : 0
    printf "\t\t\"\\%02x\" ;; %d/%d: %s / %s\n", low + high * 16, i, i + 1, (i ? name[i] : "unsupported"), (i + 1 <= count ? name[i + 1] : "padding")
  }
  print "\t)"
  print "\n\t;; Resolve an atom by a shared four-byte prefix, then length and exact suffix words."
  print "\t(func $opcode\n\t\t(result i32)\n\t\t(local $prefix i32)\n"
  print "\t\t;; Short control keywords are matched without reading past their token."
  print "\t\t(if (i32.lt_u (global.get $len) (i32.const 4))\n\t\t\t(then"
  for (n = 1; n < 4; n++) {
    present = 0
    for (i = 1; i <= count; i++) if (length(name[i]) == n) present = 1
    if (!present) continue
    printf "\t\t\t\t;; Only %d-byte control/stack keywords can match this length.\n", n
    printf "\t\t\t\t(if (i32.eq (global.get $len) (i32.const %d))\n\t\t\t\t\t(then\n", n
    for (i = 1; i <= count; i++) if (length(name[i]) == n) {
      printf "\t\t\t\t\t\t;; Recognize %s exactly.\n", name[i]
      printf "\t\t\t\t\t\t(if %s\n\t\t\t\t\t\t\t(then (return (i32.const %d)))\n\t\t\t\t\t\t)\n", mnemonic_suffix(name[i], 1), i
    }
    print "\t\t\t\t\t)\n\t\t\t\t)"
  }
  print "\t\t\t\t(return (i32.const 0))\n\t\t\t)\n\t\t)"
  print "\t\t(local.set $prefix (i32.load (global.get $tok)))"
  for (first = 1; first <= count; first++) {
    if (length(name[first]) < 4) continue
    prefix = substr(name[first], 1, 4)
    if (seen_prefix[prefix]) continue
    seen_prefix[prefix] = 1
    printf "\t\t;; Match only the %s mnemonic family.\n", prefix
    printf "\t\t(if (i32.eq (local.get $prefix) (i32.const %d))\n\t\t\t(then\n", mnemonic_word(prefix, 1, 4)
    for (n = 4; n <= longest; n++) {
      present = 0
      for (i = first; i <= count; i++) if (substr(name[i], 1, 4) == prefix && length(name[i]) == n) present = 1
      if (!present) continue
      printf "\t\t\t\t;; A suffix is examined only after its complete length matches.\n"
      printf "\t\t\t\t(if (i32.eq (global.get $len) (i32.const %d))\n\t\t\t\t\t(then\n", n
      for (i = first; i <= count; i++) if (substr(name[i], 1, 4) == prefix && length(name[i]) == n) {
        printf "\t\t\t\t\t\t;; Recognize %s from its remaining bytes.\n", name[i]
        if (n == 4) printf "\t\t\t\t\t\t(return (i32.const %d))\n", i
        else printf "\t\t\t\t\t\t(if %s\n\t\t\t\t\t\t\t(then (return (i32.const %d)))\n\t\t\t\t\t\t)\n", mnemonic_suffix(name[i], 5), i
      }
      print "\t\t\t\t\t\t(return (i32.const 0))\n\t\t\t\t\t)\n\t\t\t\t)"
    }
    print "\t\t\t\t(return (i32.const 0))\n\t\t\t)\n\t\t)"
  }
  print "\t\t(i32.const 0)\n\t)"
  print "\n\t;; Decode a wire opcode to its WAT mnemonic without compiling guest instructions."
  print "\t(func $binary-opname\n\t\t(param $byte i32)\n\t\t(result i32)"
  maximum_wire = 0
  for (i = 1; i <= count; i++) {
    if (binary[i] < 0) continue
    if (binary[i] in wire_id) exit 1
    wire_id[binary[i]] = i
    if (binary[i] > maximum_wire) maximum_wire = binary[i]
  }
  # Nullable GC variants retain their original immediate decoding, sharing only mnemonic text.
  wire_id[1045] = wire_id[1044]
  wire_id[1047] = wire_id[1046]
  wire_count = 0
  for (code = 0; code <= maximum_wire; code++) {
    if (code in wire_id) wire_order[++wire_count] = code
  }
  binary_dispatch(1, wire_count, "\t\t")
  print "\t\t(i32.const 0)\n\t)"
  print "\n\t;; Return the number of operands consumed by a known opcode."
  print "\t(func $inputs\n\t\t(param $op i32)\n\t\t(result i32)\n"
  print "\t\t;; Scalar instructions use the compact effect table directly."
  print "\t\t(if (i32.le_u (local.get $op) (i32.const 202)) (then (return (i32.shr_u (i32.load8_u (i32.add (i32.const 3072) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 4)))))"
  effect_dispatch("inputs")
  print "\t\t(i32.shr_u (i32.load8_u (i32.add (i32.const 3072) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 4))\n\t)"
  print "\n\t;; Return the number of results produced by a known opcode."
  print "\t(func $outputs\n\t\t(param $op i32)\n\t\t(result i32)\n"
  print "\t\t;; Scalar instructions use the compact effect table directly."
  print "\t\t(if (i32.le_u (local.get $op) (i32.const 202)) (then (return (i32.and (i32.load8_u (i32.add (i32.const 3072) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 15)))))"
  effect_dispatch("outputs")
  print "\t\t(i32.and (i32.load8_u (i32.add (i32.const 3072) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 15))\n\t)"
  print "\n\t;; Apply a unary or binary integer operation after the runtime checks trap conditions."
  print "\t(func $apply\n\t\t(param $op i32)\n\t\t(param $a i32)\n\t\t(param $b i32)\n\t\t(result i32)\n"
  # Zero tests are frequent control predicates; emit them before the general numeric scan.
  for (priority = 1; priority <= 2; priority++) {
    for (i = 1; i <= count; i++) {
      if ((name[i] == "i32.eqz") != (priority == 1)) continue
      if (i > 60 || operation[i] == "const" || operation[i] == "drop" || operation[i] == "nop" || operation[i] == "local" || operation[i] == "call" || operation[i] == "control" || operation[i] == "resource") continue
      printf "\t\t;; Execute %s using operands in source stack order.\n", name[i]
      printf "\t\t(if (i32.eq (local.get $op) (i32.const %d))\n", id[i]
      printf "\t\t\t(then\n\t\t\t\t(return (%s (local.get $a)", operation[i]
      if (inputs[i] == 2) printf " (local.get $b)"
      print "))\n\t\t\t)\n\t\t)"
    }
  }
  print "\t\t(i32.const 0)\n\t)"

  print "\n\t;; Return an opcode's scalar operand type; stores use their address type for the second pop."
  print "\t(func $operand-type\n\t\t(param $op i32)\n\t\t(param $position i32)\n\t\t(result i32)"
  print "\t\t;; Memory address operands use the selected logical address width."
  print "\t\t(if (i32.or (i32.eq (local.get $op) (i32.const 52)) (i32.and (call $memory-op (local.get $op)) (i32.eq (local.get $position) (i32.sub (call $inputs (local.get $op)) (i32.const 1))))) (then (return (global.get $memory-type))))"
  print "\t\t;; Bulk memory lengths and addresses use the logical width; fill values and data indices stay i32."
  print "\t\t(if (i32.or (i32.and (i32.eq (local.get $op) (i32.const 187)) (i32.eq (local.get $position) (i32.const 2))) (i32.and (i32.eq (local.get $op) (i32.const 188)) (i32.ne (local.get $position) (i32.const 1)))) (then (return (global.get $memory-type))))"
  print "\t\t(if (i32.and (i32.eq (local.get $op) (i32.const 189)) (i32.eq (local.get $position) (i32.const 2))) (then (return (global.get $memory-type))))"
  print "\t\t;; Memory copies permit independently typed sources and use the narrower length type."
  print "\t\t(if (i32.eq (local.get $op) (i32.const 187)) (then (return (select (global.get $memory-source-type) (select (global.get $memory-type) (i32.const 1) (i32.eq (global.get $memory-type) (global.get $memory-source-type))) (local.get $position)))))"
  print "\t\t;; Indexed table operations consume their selected logical address width."
  print "\t\t(if (i32.or (i32.eq (local.get $op) (i32.const 198)) (i32.or (i32.and (i32.eq (local.get $op) (i32.const 199)) (local.get $position)) (i32.or (i32.and (i32.eq (local.get $op) (i32.const 200)) (i32.eqz (local.get $position))) (i32.and (i32.eq (local.get $op) (i32.const 201)) (i32.ne (local.get $position) (i32.const 1)))))) (then (return (global.get $table-address-type))))"
  print "\t\t;; table.init has a wide destination but thirty-two-bit source and segment length."
  print "\t\t(if (i32.and (i32.eq (local.get $op) (i32.const 197)) (i32.eq (local.get $position) (i32.const 2))) (then (return (global.get $table-address-type))))"
  print "\t\t;; Copy source and destination widths can differ; its length uses the narrower width."
  print "\t\t(if (i32.eq (local.get $op) (i32.const 192)) (then (return (select (global.get $table-address-type) (select (global.get $table-source-type) (select (global.get $table-address-type) (i32.const 1) (i32.eq (global.get $table-source-type) (global.get $table-address-type))) (local.get $position)) (i32.eq (local.get $position) (i32.const 2))))))"
  print "\t\t;; Table set consumes a function reference followed by its i32 slot index."
  print "\t\t(if (i32.and (i32.eq (local.get $op) (i32.const 199)) (local.get $position))\n\t\t\t(then (return (i32.const 1)))\n\t\t)"
  print "\t\t;; Growth pops its i32 delta before its initializer; fill pops length, reference, index."
  print "\t\t(if (i32.or (i32.and (i32.eq (local.get $op) (i32.const 200)) (local.get $position)) (i32.and (i32.eq (local.get $op) (i32.const 201)) (i32.eq (local.get $position) (i32.const 1))))\n\t\t\t(then (return (global.get $guest-table-type)))\n\t\t)"
  print "\t\t;; Table set's value type belongs to the selected table."
  print "\t\t(if (i32.eq (local.get $op) (i32.const 199)) (then (return (global.get $guest-table-type))))"
  print "\t\t;; Stores consume a typed value followed by an i32 address."
  print "\t\t(if (i32.and (call $store-op (local.get $op)) (local.get $position))\n\t\t\t(then (return (i32.const 1)))\n\t\t)"
  print "\t\t;; Scalar instructions use the compact effect table directly."
  print "\t\t(if (i32.le_u (local.get $op) (i32.const 202)) (then (return (i32.shr_u (i32.load8_u (i32.add (i32.const 3073) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 4)))))"
  effect_dispatch("operand-type")
  print "\t\t(i32.shr_u (i32.load8_u (i32.add (i32.const 3073) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 4))\n\t)"
  print "\n\t;; Return an opcode's declared scalar result type for typed validation."
  print "\t(func $output-type\n\t\t(param $op i32)\n\t\t(result i32)"
  print "\t\t;; Memory size and growth return the logical address type."
  print "\t\t(if (i32.or (i32.eq (local.get $op) (i32.const 51)) (i32.eq (local.get $op) (i32.const 52))) (then (return (global.get $memory-type))))"
  print "\t\t;; Table size and growth return the selected logical index type."
  print "\t\t(if (i32.or (i32.eq (local.get $op) (i32.const 191)) (i32.eq (local.get $op) (i32.const 200))) (then (return (global.get $table-address-type))))"
  print "\t\t;; Table get returns the selected table's reference type."
  print "\t\t(if (i32.eq (local.get $op) (i32.const 198)) (then (return (global.get $guest-table-type))))"
  print "\t\t;; Scalar instructions use the compact effect table directly."
  print "\t\t(if (i32.le_u (local.get $op) (i32.const 202)) (then (return (i32.and (i32.load8_u (i32.add (i32.const 3073) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 15)))))"
  effect_dispatch("output-type")
  print "\t\t(i32.and (i32.load8_u (i32.add (i32.const 3073) (i32.mul (local.get $op) (i32.const 2)))) (i32.const 15))\n\t)"
  print "\n\t;; Apply an i64 numeric operation or width conversion after runtime trap checks."
  print "\t(func $apply64\n\t\t(param $op i32)\n\t\t(param $a i64)\n\t\t(param $b i64)\n\t\t(result i64)"
  # Zero tests are frequent control predicates; emit them before the general numeric scan.
  for (priority = 1; priority <= 2; priority++) {
    for (i = 62; i <= count; i++) {
      if ((name[i] == "i64.eqz") != (priority == 1)) continue
      if (i > 93 && operation[i] != "integerextend") continue
      printf "\t\t;; Execute %s with full-width integer operands.\n", name[i]
      printf "\t\t(if (i32.eq (local.get $op) (i32.const %d))\n\t\t\t(then\n\t\t\t\t(return ", i
      if (i >= 77 && i <= 87) printf "(i64.extend_i32_u "
      if (i == 91) printf "(i64.extend_i32_s (i32.wrap_i64 (local.get $a)))"
      else if (operation[i] == "integerextend" && inputtype[i] == 1) printf "(i64.extend_i32_s (%s (i32.wrap_i64 (local.get $a))))", name[i]
      else if (i == 92 || i == 93) printf "(%s (i32.wrap_i64 (local.get $a)))", name[i]
      else {
        printf "(%s (local.get $a)", name[i]
        if (inputs[i] == 2) printf " (local.get $b)"
        printf ")"
      }
      if (i >= 77 && i <= 87) printf ")"
      print ")\n\t\t\t)\n\t\t)"
    }
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
  print "\t\t;; Vector accesses share the memory declaration and alignment rules."
  print "\t\t(if (call $vector-memory-width (local.get $op)) (then (return (i32.const 1))))"
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
