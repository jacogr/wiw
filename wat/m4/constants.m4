m4_dnl Shared interpreter status codes, value types, dispatch families and record layout.
m4_dnl
m4_dnl Status codes shared with the Node host ABI.
m4_define(<!M4_ERR_SUCCESS!>,<!0!>)m4_dnl
m4_define(<!M4_ERR_SYNTAX!>,<!1!>)m4_dnl
m4_define(<!M4_ERR_UNSUPPORTED!>,<!2!>)m4_dnl
m4_define(<!M4_ERR_INTEGER_RANGE!>,<!3!>)m4_dnl
m4_define(<!M4_ERR_UNKNOWN_EXPORT!>,<!4!>)m4_dnl
m4_define(<!M4_ERR_INVALID_BUFFER!>,<!5!>)m4_dnl
m4_define(<!M4_ERR_RESOURCE_LIMIT!>,<!6!>)m4_dnl
m4_define(<!M4_ERR_OPERAND_STACK!>,<!7!>)m4_dnl
m4_define(<!M4_ERR_DIVIDE_BY_ZERO!>,<!8!>)m4_dnl
m4_define(<!M4_ERR_INTEGER_OVERFLOW!>,<!9!>)m4_dnl
m4_define(<!M4_ERR_INVALID_REFERENCE!>,<!10!>)m4_dnl
m4_define(<!M4_ERR_ARGUMENT_MISMATCH!>,<!11!>)m4_dnl
m4_define(<!M4_ERR_EXHAUSTED_FUEL!>,<!12!>)m4_dnl
m4_define(<!M4_ERR_UNREACHABLE!>,<!13!>)m4_dnl
m4_define(<!M4_ERR_MEMORY_BOUNDS!>,<!14!>)m4_dnl
m4_define(<!M4_ERR_MEMORY_LIMITS!>,<!15!>)m4_dnl
m4_define(<!M4_ERR_IMMUTABLE_GLOBAL!>,<!16!>)m4_dnl
m4_define(<!M4_ERR_INTERPRETER!>,<!17!>)m4_dnl
m4_define(<!M4_ERR_EXPORT_KIND!>,<!18!>)m4_dnl
m4_define(<!M4_ERR_ALIGNMENT!>,<!19!>)m4_dnl
m4_define(<!M4_ERR_HOST_IMPORT!>,<!20!>)m4_dnl
m4_define(<!M4_ERR_INVALID_RESUME!>,<!21!>)m4_dnl
m4_define(<!M4_ERR_SUSPENDED_REENTRY!>,<!22!>)m4_dnl
m4_define(<!M4_ERR_HOST_VALUE_TYPE!>,<!23!>)m4_dnl
m4_define(<!M4_ERR_UNDEFINED_ELEMENT!>,<!24!>)m4_dnl
m4_define(<!M4_ERR_INDIRECT_TYPE!>,<!25!>)m4_dnl
m4_define(<!M4_ERR_TABLE_LIMITS!>,<!26!>)m4_dnl
m4_define(<!M4_ERR_ELEMENT_BOUNDS!>,<!27!>)m4_dnl
m4_define(<!M4_ERR_INVALID_CONVERSION!>,<!28!>)m4_dnl
m4_define(<!M4_ERR_NOT_INITIALIZED!>,<!29!>)m4_dnl
m4_define(<!M4_ERR_TABLE_BOUNDS!>,<!30!>)m4_dnl
m4_define(<!M4_ERR_NULL_REFERENCE!>,<!31!>)m4_dnl
m4_define(<!M4_ERR_CAST_FAILURE!>,<!32!>)m4_dnl
m4_define(<!M4_ERR_ARRAY_BOUNDS!>,<!33!>)m4_dnl
m4_define(<!M4_ERR_UNCAUGHT_EXCEPTION!>,<!34!>)m4_dnl
m4_define(<!M4_ERR_ABORTED!>,<!35!>)m4_dnl
m4_dnl
m4_dnl Generated runtime dispatch families; zero uses the general path.
m4_define(<!M4_ROUTE_GENERAL!>,<!0!>)m4_dnl
m4_define(<!M4_ROUTE_CONSTANT_LOCAL!>,<!1!>)m4_dnl
m4_define(<!M4_ROUTE_INTEGER!>,<!2!>)m4_dnl
m4_define(<!M4_ROUTE_CONTROL!>,<!3!>)m4_dnl
m4_define(<!M4_ROUTE_GLOBAL_REFERENCE!>,<!4!>)m4_dnl
m4_define(<!M4_ROUTE_CALL!>,<!5!>)m4_dnl
m4_define(<!M4_ROUTE_UNREACHABLE!>,<!6!>)m4_dnl
m4_define(<!M4_ROUTE_RETURN!>,<!7!>)m4_dnl
m4_define(<!M4_ROUTE_THROW!>,<!8!>)m4_dnl
m4_define(<!M4_ROUTE_CAST_BRANCH!>,<!9!>)m4_dnl
m4_define(<!M4_ROUTE_REFERENCE_BRANCH!>,<!10!>)m4_dnl
m4_define(<!M4_ROUTE_BRANCH!>,<!11!>)m4_dnl
m4_define(<!M4_ROUTE_SELECT!>,<!12!>)m4_dnl
m4_define(<!M4_ROUTE_GC_AGGREGATE!>,<!13!>)m4_dnl
m4_define(<!M4_ROUTE_TABLE!>,<!14!>)m4_dnl
m4_define(<!M4_ROUTE_MEMORY!>,<!15!>)m4_dnl
m4_dnl
m4_dnl Scalar/vector value type IDs.
m4_define(<!M4_TYPE_I32!>,<!1!>)m4_dnl
m4_define(<!M4_TYPE_I64!>,<!2!>)m4_dnl
m4_define(<!M4_TYPE_F32!>,<!3!>)m4_dnl
m4_define(<!M4_TYPE_F64!>,<!4!>)m4_dnl
m4_define(<!M4_TYPE_V128!>,<!5!>)m4_dnl
m4_dnl
m4_dnl Reference hierarchy IDs used by trusted host table checks.
m4_define(<!M4_REF_EXN_NULLABLE!>,<!32!>)m4_dnl
m4_define(<!M4_REF_EXN_NONNULL!>,<!33!>)m4_dnl
m4_dnl
m4_dnl Record widths, packed table locations and field offsets.
m4_define(<!M4_TABLE_ELEMENT_TYPE_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_TAG_HEAP_TYPE_OFFSET!>,<!24!>)m4_dnl
m4_define(<!M4_SLOT_BYTES!>,<!8!>)m4_dnl
m4_define(<!M4_GC_SLOT_BYTES!>,<!16!>)m4_dnl
m4_define(<!M4_SLOT_SHIFT!>,<!3!>)m4_dnl
m4_define(<!M4_INSTRUCTION_BYTES!>,<!16!>)m4_dnl
m4_define(<!M4_INSTRUCTION_SHIFT!>,<!4!>)m4_dnl
m4_define(<!M4_EFFECT_TABLE_BASE!>,<!3072!>)m4_dnl
m4_define(<!M4_ROUTE_TABLE_BASE!>,<!3480!>)m4_dnl
m4_define(<!M4_NIBBLE_MASK!>,<!15!>)m4_dnl
m4_define(<!M4_NIBBLE_SHIFT!>,<!4!>)m4_dnl
m4_define(<!M4_INSTRUCTION_IMMEDIATE_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_INSTRUCTION_SOURCE_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_INSTRUCTION_EXTRA_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_CALL_END_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_CALL_STACK_BASE_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_CALL_FUNCTION_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_CALL_LOCALS_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_CONTROL_START_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_CONTROL_END_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_CONTROL_STACK_BASE_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_CONTROL_RESULT_SHAPE_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_CONTROL_PARAMETER_SHAPE_OFFSET!>,<!20!>)m4_dnl
m4_define(<!M4_FUNCTION_START_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_FUNCTION_END_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_FUNCTION_PARAMETERS_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_FUNCTION_LOCALS_OFFSET!>,<!20!>)m4_dnl
m4_define(<!M4_FUNCTION_RESULT_SHAPE_OFFSET!>,<!24!>)m4_dnl
m4_dnl
m4_dnl Numeric boundaries and opcode-specific metadata fields.
m4_define(<!M4_U32_MAX!>,<!4294967295!>)m4_dnl
m4_define(<!M4_I32_MIN!>,<!-2147483648!>)m4_dnl
m4_define(<!M4_I64_MIN!>,<!-9223372036854775808!>)m4_dnl
m4_define(<!M4_WORD_BITS!>,<!32!>)m4_dnl
m4_define(<!M4_METADATA_ELSE_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_METADATA_PARAMETER_SHAPE_OFFSET!>,<!20!>)m4_dnl
m4_define(<!M4_GLOBAL_VALUE_OFFSET!>,<!24!>)m4_dnl
m4_define(<!M4_GLOBAL_HIGH_OFFSET!>,<!72!>)m4_dnl
m4_define(<!M4_MEMORY_PAGES_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_MEMORY_BASE_OFFSET!>,<!20!>)m4_dnl
m4_define(<!M4_MEMORY_ADDRESS_TYPE_OFFSET!>,<!24!>)m4_dnl
m4_define(<!M4_TABLE_ADDRESS_TYPE_OFFSET!>,<!24!>)m4_dnl
m4_define(<!M4_ELEMENT_LIVE_LENGTH_OFFSET!>,<!44!>)m4_dnl
m4_define(<!M4_VECTOR_HIGH_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_VECTOR_BYTES!>,<!16!>)m4_dnl
m4_define(<!M4_MEMORY_ACCESS_WIDTH_OFFSET!>,<!28!>)m4_dnl
m4_define(<!M4_MEMORY_OPERAND_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_BULK_SOURCE_MEMORY_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_BULK_SOURCE_TABLE_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_BULK_SOURCE_OFFSET!>,<!16!>)m4_dnl
m4_define(<!M4_BULK_SOURCE_ADDRESS_TYPE_OFFSET!>,<!24!>)m4_dnl
m4_define(<!M4_BRANCH_TYPE_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_U32_BYTES!>,<!4!>)m4_dnl
m4_define(<!M4_FUNCTION_IMPORTED!>,<!-1!>)m4_dnl
m4_define(<!M4_INDEX_ABSENT!>,<!-1!>)m4_dnl
m4_define(<!M4_TABLE_OPERAND_OFFSET!>,<!8!>)m4_dnl
m4_dnl Decimal digit and scale chunks fit in one unsigned multiplier limb.
m4_define(<!M4_DECIMAL_RADIX!>,<!10!>)m4_dnl
m4_define(<!M4_DECIMAL_CHUNK_DIGITS!>,<!9!>)m4_dnl
m4_define(<!M4_DECIMAL_CHUNK_RADIX!>,<!1000000000!>)m4_dnl
m4_dnl Fixed-width SIMD lane addressing and masks.
m4_define(<!M4_VECTOR_HALF_BITS!>,<!64!>)m4_dnl
m4_define(<!M4_VECTOR_LOW_LANE!>,<!0!>)m4_dnl
m4_define(<!M4_VECTOR_HIGH_LANE!>,<!1!>)m4_dnl
m4_define(<!M4_LANE8_SHIFT!>,<!3!>)m4_dnl
m4_define(<!M4_LANE16_SHIFT!>,<!4!>)m4_dnl
m4_define(<!M4_LANE32_SHIFT!>,<!5!>)m4_dnl
m4_define(<!M4_LANE64_SHIFT!>,<!6!>)m4_dnl
m4_define(<!M4_U8_MAX!>,<!255!>)m4_dnl
m4_define(<!M4_U16_MAX!>,<!65535!>)m4_dnl
m4_dnl Exact integer scratch buffers contain a header and 32-bit limbs.
m4_define(<!M4_BIG_LIMB_BYTES!>,<!4!>)m4_dnl
m4_define(<!M4_BIG_LIMB_BITS!>,<!32!>)m4_dnl
m4_define(<!M4_BIG_LIMB_CAPACITY!>,<!1023!>)m4_dnl
m4_dnl Seven hexadecimal digits form a multiplier of 16^7 within one unsigned limb.
m4_define(<!M4_HEX_CHUNK_RADIX!>,<!268435456!>)m4_dnl
m4_dnl The four exact WAT whitespace bytes, shared by helper and inline scanner checks.
m4_define(<!M4_BYTE_SPACE!>,<!32!>)m4_dnl
m4_define(<!M4_BYTE_TAB!>,<!9!>)m4_dnl
m4_define(<!M4_BYTE_LF!>,<!10!>)m4_dnl
m4_define(<!M4_BYTE_CR!>,<!13!>)m4_dnl
m4_dnl Bytes that can introduce WAT comments or annotations.
m4_define(<!M4_BYTE_LPAREN!>,<!40!>)m4_dnl
m4_define(<!M4_BYTE_SEMICOLON!>,<!59!>)m4_dnl
m4_dnl ASCII digit decoding uses unsigned ranges and the ASCII lowercase case bit.
m4_define(<!M4_ASCII_ZERO!>,<!48!>)m4_dnl
m4_define(<!M4_DECIMAL_LAST_DIGIT!>,<!9!>)m4_dnl
m4_define(<!M4_ASCII_CASE_BIT!>,<!32!>)m4_dnl
m4_define(<!M4_ASCII_LOWER_A!>,<!97!>)m4_dnl
m4_define(<!M4_HEX_LAST_LETTER!>,<!5!>)m4_dnl
m4_dnl Runtime control records contain eight 32-bit fields.
m4_define(<!M4_CONTROL_BYTES!>,<!32!>)m4_dnl

m4_dnl Shapes below this address encode void or one value type; larger shapes are vectors.
m4_define(<!M4_SHAPE_VECTOR_MIN!>,<!1048576!>)m4_dnl

m4_dnl Little-endian two-byte lexer delimiters, read only after checking the full pair.
m4_define(<!M4_PAIR_LINE_COMMENT!>,<!15163!>)m4_dnl
m4_define(<!M4_PAIR_BLOCK_COMMENT_OPEN!>,<!15144!>)m4_dnl
m4_define(<!M4_PAIR_BLOCK_COMMENT_CLOSE!>,<!10555!>)m4_dnl
m4_define(<!M4_PAIR_ANNOTATION_OPEN!>,<!16424!>)m4_dnl

m4_dnl Token-prefix bytes used after the scanner has proved the cursor is in range.
m4_define(<!M4_BYTE_DOLLAR!>,<!36!>)m4_dnl
m4_define(<!M4_BYTE_RPAREN!>,<!41!>)m4_dnl
m4_define(<!M4_BYTE_QUOTE!>,<!34!>)m4_dnl

m4_dnl Two-byte comparison tails never read beyond the requested span.
m4_define(<!M4_HALFWORD_BYTES!>,<!2!>)m4_dnl

m4_dnl Four-byte comparison words use bounded i32 loads.
m4_define(<!M4_WORD_BYTES!>,<!4!>)m4_dnl

m4_dnl Eight-byte comparison words use bounded i64 loads.
m4_define(<!M4_DOUBLEWORD_BYTES!>,<!8!>)m4_dnl

m4_dnl Repeated byte lanes used by bounded eight-byte token scanning.
m4_define(<!M4_BYTE_LANES_SPACE!>,<!0x2020202020202020!>)m4_dnl
m4_define(<!M4_BYTE_LANES_TAB!>,<!0x0909090909090909!>)m4_dnl
m4_define(<!M4_BYTE_LANES_HIGH_BIT!>,<!0x8080808080808080!>)m4_dnl
m4_define(<!M4_BYTE_LANES_ONE!>,<!0x0101010101010101!>)m4_dnl
m4_define(<!M4_BYTE_LANES_ATOM_MIN!>,<!0x2121212121212121!>)m4_dnl
m4_define(<!M4_BYTE_LANES_QUOTE!>,<!0x2222222222222222!>)m4_dnl
m4_define(<!M4_BYTE_LANES_LPAREN!>,<!0x2828282828282828!>)m4_dnl
m4_define(<!M4_BYTE_LANES_RPAREN!>,<!0x2929292929292929!>)m4_dnl
m4_define(<!M4_BYTE_LANES_SEMICOLON!>,<!0x3b3b3b3b3b3b3b3b!>)m4_dnl

m4_dnl Packed scalar effects hold operand/result type nibbles in the second byte.
m4_define(<!M4_EFFECT_OPERAND_SHIFT!>,<!12!>)m4_dnl
m4_define(<!M4_BYTE_SHIFT!>,<!8!>)m4_dnl

m4_dnl Fresh host metadata snapshots use counted i32 type vectors in existing scratch memory.
m4_define(<!M4_HOST_SIGNATURE_RESULTS_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_HOST_SIGNATURE_TYPES_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_HOST_RESULT_BASE_OFFSET!>,<!4!>)m4_dnl
m4_define(<!M4_HOST_RESULT_HIGH_OFFSET!>,<!8!>)m4_dnl
m4_define(<!M4_HOST_RESULT_TYPES_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_TYPE_BYTES!>,<!4!>)m4_dnl
m4_dnl Fusion consumes original records while retaining two temporary operand-capacity boundaries.
m4_define(<!M4_FUSION_STACK_MAX!>,<!m4_eval(M4_CAP_OPERANDS - 2)!>)m4_dnl
m4_define(<!M4_FUSION_TAIL_BYTES!>,<!m4_eval(M4_INSTRUCTION_BYTES * 2)!>)m4_dnl
m4_define(<!M4_FUSION_BYTES!>,<!m4_eval(M4_INSTRUCTION_BYTES * 3)!>)m4_dnl
m4_define(<!M4_FUSION_BINARY_SOURCE_OFFSET!>,<!m4_eval(M4_INSTRUCTION_BYTES * 2 + M4_INSTRUCTION_SOURCE_OFFSET)!>)m4_dnl
m4_dnl Completed implicit type index plus one; zero requires the ordinary structural lookup.
m4_define(<!M4_FUNCTION_INTERNED_TYPE_OFFSET!>,<!24!>)m4_dnl
m4_dnl A validated local.get reuses its consumed name-length field for a move/drop or binary opcode.
m4_define(<!M4_FUSION_OPERATOR_OFFSET!>,<!M4_INSTRUCTION_EXTRA_OFFSET!>)m4_dnl

m4_dnl Convert a bit position into its byte lane within a word.
m4_define(<!M4_BYTE_BIT_SHIFT!>,<!3!>)m4_dnl

m4_dnl Decoded string/data capacity and raw ASCII scan thresholds.
m4_define(<!M4_DATA_BYTES!>,<!65536!>)m4_dnl
m4_define(<!M4_ASCII_LIMIT!>,<!128!>)m4_dnl
m4_define(<!M4_BYTE_BACKSLASH!>,<!92!>)m4_dnl
m4_define(<!M4_BYTE_DEL!>,<!127!>)m4_dnl


m4_dnl Fold word hash high bits into the low bucket bits.
m4_define(<!M4_NAME_HASH_FOLD_SHIFT!>,<!16!>)m4_dnl

m4_dnl Clear each byte's low bit when comparing adjacent punctuation codes.
m4_define(<!M4_BYTE_LANES_CLEAR_LOW_BIT!>,<!0xfefefefefefefefe!>)m4_dnl

m4_dnl Keep the low two bytes of each i32 pair sum, preserving modulo-i16 truncation.
m4_define(<!M4_VECTOR_DOT_PACK_PAIRS!>,<!0 1 4 5 8 9 12 13 16 17 20 21 24 25 28 29!>)m4_dnl
m4_dnl Exchange neighboring i32 pair sums so addition combines groups of four source bytes.
m4_define(<!M4_VECTOR_DOT_SWAP_PAIRS!>,<!4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11!>)m4_dnl
m4_dnl Select one i32 sum from each duplicated pair across both source halves.
m4_define(<!M4_VECTOR_DOT_PACK_QUADS!>,<!0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27!>)m4_dnl

m4_dnl Binary string escapes consist of a backslash and two ASCII hex digits.
m4_define(<!M4_BINARY_TEXT_BYTES!>,<!1048576!>)m4_dnl
m4_define(<!M4_BINARY_HEX_DIGITS_BASE!>,<!3877!>)m4_dnl
m4_define(<!M4_BINARY_ESCAPE_BYTES!>,<!3!>)m4_dnl
m4_define(<!M4_BYTE_BITS!>,<!8!>)m4_dnl
m4_define(<!M4_BINARY_STRING_SUFFIX_BYTES!>,<!2!>)m4_dnl

m4_dnl An initialization flag packs its scope depth above the preceding one-based local link.
m4_dnl Both bounded local indices and control depths fit their sixteen-bit fields.
m4_define(<!M4_LOCAL_INIT_SCOPE_SHIFT!>,<!16!>)m4_dnl
m4_define(<!M4_LOCAL_INIT_LINK_MASK!>,<!65535!>)m4_dnl
m4_dnl Parameter flags are permanently initialized and never enter the local rollback chain.
m4_define(<!M4_LOCAL_INIT_PERMANENT!>,<!-1!>)m4_dnl
m4_dnl Reject configurations whose one-based local links or scope depths cannot fit the packed flag.
m4_ifelse(m4_eval(M4_CAP_LOCALS <= M4_LOCAL_INIT_LINK_MASK && M4_CAP_CONTROLS <= M4_LOCAL_INIT_LINK_MASK),<!1!>,<!!>,<!m4_errprint(<!Local initialization links and scopes require sixteen-bit bounds.
!>)m4_m4exit(1)!>)m4_dnl

m4_dnl A complete signature header and its 128 parameter type words share one bounded record.
m4_define(<!M4_SIGNATURE_BYTES!>,<!544!>)m4_dnl

m4_dnl Global alias and import category fields are explicitly reset before publishing a live descriptor.
m4_define(<!M4_GLOBAL_ALIAS_OFFSET!>,<!60!>)m4_dnl
m4_define(<!M4_IMPORT_KIND_OFFSET!>,<!24!>)m4_dnl

m4_dnl Memory descriptors include logical limits, physical pages/base and import alias fields.
m4_define(<!M4_MEMORY_DESCRIPTOR_BYTES!>,<!64!>)m4_dnl

m4_dnl Validated void-function guard: i32 parameter index plus one, zero for ordinary entry.
m4_define(<!M4_FUNCTION_GUARD_PARAMETER_OFFSET!>,<!28!>)m4_dnl
m4_define(<!M4_GUARD_RETURN_FUEL!>,<!3!>)m4_dnl

m4_dnl Negative local fusion markers distinguish a scalar load from positive move/binary opcodes.
m4_define(<!M4_FUSION_LOAD_FLAG!>,<!2147483648!>)m4_dnl

m4_dnl Non-moving GC blocks retain the existing sixteen-byte object header.
m4_define(<!M4_GC_ARENA_BYTES!>,<!16777216!>)m4_dnl
m4_define(<!M4_GC_HEADER_BYTES!>,<!16!>)m4_dnl
m4_define(<!M4_GC_FLAGS_OFFSET!>,<!12!>)m4_dnl
m4_define(<!M4_GC_FREE!>,<!1!>)m4_dnl
m4_define(<!M4_GC_MARK!>,<!2!>)m4_dnl
m4_define(<!M4_GC_HOST_ROOT!>,<!4!>)m4_dnl
m4_define(<!M4_GC_SIZE_MASK!>,<!-16!>)m4_dnl
m4_define(<!M4_GC_OBJECT_TAG!>,<!1073741824!>)m4_dnl
m4_define(<!M4_GC_EXCEPTION_TAG!>,<!268435456!>)m4_dnl
m4_define(<!M4_GC_TAG_MASK!>,<!4026531840!>)m4_dnl
m4_define(<!M4_GC_ADDRESS_MASK!>,<!268435455!>)m4_dnl
