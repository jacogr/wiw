	;; Return a load/store's natural width in bytes for alignment and bounds checks.
	(func $access-width
		(param $op i32)
		(result i32)

		;; Vector accesses have their own declared byte widths.
		(if (call $vector-memory-width (local.get $op))
			(then
				(return (call $vector-memory-width (local.get $op)))
			)
		)
		;; Double-precision loads and stores access eight bytes.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_F64_LOAD)) (i32.eq (local.get $op) (i32.const M4_OP_F64_STORE)))
			(then
				(return (i32.const 8))
			)
		)
		;; Single-precision accesses preserve four raw IEEE bytes.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_F32_LOAD)) (i32.eq (local.get $op) (i32.const M4_OP_F32_STORE)))
			(then
				(return (i32.const 4))
			)
		)
		;; Full-width i64 accesses require eight bytes and allow alignments up to eight.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD)) (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE)))
			(then
				(return (i32.const 8))
			)
		)
		;; Narrow i64 loads/stores still check their actual accessed width.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD32_S))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD32_U)) (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE32)))
			)
			(then
				(return (i32.const 4))
			)
		)
		;; Halfword i64 accesses read or write two bytes.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD16_S))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD16_U)) (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE16)))
			)
			(then
				(return (i32.const 2))
			)
		)
		;; Full i32 loads and stores access four bytes.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD)) (i32.eq (local.get $op) (i32.const M4_OP_I32_STORE)))
			(then
				(return (i32.const 4))
			)
		)
		;; Sixteen-bit loads and stores access two bytes.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD16_S))
				(i32.or (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD16_U)) (i32.eq (local.get $op) (i32.const M4_OP_I32_STORE16)))
			)
			(then
				(return (i32.const 2))
			)
		)
		(i32.const 1)
	)

	;; Recognize an attribute prefix without mistaking an ordinary opcode for an immediate.
	(func $attribute
		(param $p i32)
		(param $n i32)
		(result i32)

		;; Reject wrong token kinds or lengths before reading either byte span.
		(if
			(i32.or
				(i32.ne (global.get $kind) (i32.const 3))
				(i32.lt_u (global.get $len) (local.get $n))
			)
			(then (return (i32.const 0)))
		)
		(call $equal (global.get $tok) (local.get $p) (local.get $n))
	)

	;; Decode the unsigned suffix of a memory attribute and advance past its original token.
	(func $attribute-index
		(param $length i32)
		(result i32)

		(global.set $tok (i32.add (global.get $tok) (local.get $length)))
		(global.set $len (i32.sub (global.get $len) (local.get $length)))
		;; An empty attribute is invalid without reading beyond its token span.
		(if (i32.eqz (global.get $len))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return (i32.const 0))
			)
		)
		(call $index)
	)

	;; Parse offset then alignment; record offset as the immediate and alignment as extra metadata.
	(func $memarg
		(param $op i32)
		(result i32)
		(local $offset i64)
		(local $record i32)
		(local $start i32)
		(local $named i32)
		(local $alignment i32)
		(local $at i32)

		(local.set $record (call $new-memory-immediate))
		(local.set $start (global.get $tok))
		(local.set $named (call $named))
		;; A lone number on a lane instruction denotes its lane rather than its optional memory.
		(if (call $table-reference (i32.add (local.get $record) (i32.const 8)))
			(then
				(local.set $at
					(i32.or
						(call $attribute (i32.const 99) (i32.const 7))
						(call $attribute (i32.const 106) (i32.const 6))
					)
				)
				;; Another numeric immediate also distinguishes an explicit memory selector from a lane.
				(if
					(i32.and
						(i32.eq (global.get $kind) (i32.const 3))
						(i32.and
							(i32.ge_u (i32.load8_u (global.get $tok)) (i32.const 48))
							(i32.le_u (i32.load8_u (global.get $tok)) (i32.const 57))
						)
					)
					(then
						(local.set $at (i32.const 1))
					)
				)
				;; Rewind a numeric lane when no following memory attribute or lane number exists.
				(if
					(i32.and
						(i32.ne (call $vector-memory-lanes (local.get $op)) (i32.const 0))
						(i32.and (i32.eqz (local.get $named)) (i32.eqz (local.get $at)))
					)
					(then
						(i64.store offset=8 (local.get $record) (i64.const 0))
						(global.set $pos (local.get $start))
						(call $next)
					)
				)
			)
		)
		(local.set $alignment (call $access-width (local.get $op)))
		;; An omitted offset defaults to zero.
		(if (call $attribute (i32.const 99) (i32.const 7))
			(then
				(global.set $tok (i32.add (global.get $tok) (i32.const 7)))
				(global.set $len (i32.sub (global.get $len) (i32.const 7)))
				(local.set $offset (call $index64))
			)
		)
		;; Alignment is a byte count, defaults to natural width, and follows offset.
		(if (call $attribute (i32.const 106) (i32.const 6))
			(then
				(local.set $at (global.get $tok))
				(local.set $alignment (call $attribute-index (i32.const 6)))
				;; Require a positive power of two no larger than the accessed width.
				(if
					(i32.or
						(i32.eqz (local.get $alignment))
						(i32.or
							(i32.gt_u (local.get $alignment) (call $access-width (local.get $op)))
							(i32.ne
								(i32.and (local.get $alignment) (i32.sub (local.get $alignment) (i32.const 1)))
								(i32.const 0)
							)
						)
					)
					(then
						(global.set $tok (local.get $at))
						(call $fail
							(select
								(i32.const 1)
								(i32.const 19)
								(i32.or
									(i32.eqz (local.get $alignment))
									(i32.ne
										(i32.and (local.get $alignment) (i32.sub (local.get $alignment) (i32.const 1)))
										(i32.const 0)
									)
								)
							)
						)
					)
				)
			)
		)
		(global.set $immediate-length (local.get $alignment))
		(i64.store (local.get $record) (local.get $offset))
		(local.get $record)
	)

	;; Check resource references and mutability regardless of validation reachability.
	(func $validate-resource
		(param $op i32)
		(param $index i32)

		;; All memory instructions require the module to declare its default memory.
		(if (i32.ge_u (local.get $op) (i32.const M4_OP_MEMORY_SIZE))
			(then
				;; A missing memory is a validation error even for dead loads/stores.
				(if (i32.eqz (global.get $memory-present))
					(then
						(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
					)
				)
				(return)
			)
		)
		;; Resolved global indices must remain inside the global table.
		(if (i32.ge_u (local.get $index) (global.get $global-count))
			(then
				(call $fail (i32.const M4_ERR_INVALID_REFERENCE))
				(return)
			)
		)
		;; global.set may only address a mutable global, including inside dead code.
		(if
			(i32.and
				(i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_SET))
				(i32.eqz (i32.load offset=8 (call $global-record (local.get $index))))
			)
			(then
				(call $fail (i32.const M4_ERR_IMMUTABLE_GLOBAL))
			)
		)
	)

	;; Ensure native backing memory contains an unsigned byte limit without exposing guest page counts.
	(func $ensure-bytes
		(param $required i64)
		(result i32)
		(local $available i64)
		(local $delta i32)

		;; Reject any backing layout whose host pointers would wrap.
		(if (i64.gt_u (local.get $required) (i64.const 4294967295))
			(then
				(return (i32.const 0))
			)
		)
		(local.set $available (i64.mul (i64.extend_i32_u (memory.size)) (i64.const 65536)))
		;; Existing backing pages can already contain the requested logical memory.
		(if (i64.le_u (local.get $required) (local.get $available))
			(then
				(return (i32.const 1))
			)
		)
		(local.set $delta
			(i32.wrap_i64
				(i64.div_u
					(i64.add (i64.sub (local.get $required) (local.get $available)) (i64.const 65535))
					(i64.const 65536)
				)
			)
		)
		(i32.ne (memory.grow (local.get $delta)) (i32.const -1))
	)

	;; Translate a guest byte range after a wide unsigned bounds check; record a guest trap on failure.
	(func $guest-address
		(param $address i32)
		(param $offset i32)
		(param $width i32)
		(result i32)
		(local $effective i64)

		(local.set $effective
			(i64.add (i64.extend_i32_u (local.get $address)) (i64.extend_i32_u (local.get $offset)))
		)
		;; Wide addition prevents wrapped addresses from reaching interpreter records.
		(if
			(i64.gt_u
				(i64.add (local.get $effective) (i64.extend_i32_u (local.get $width)))
				(i64.mul (i64.extend_i32_u (global.get $guest-pages)) (i64.const 65536))
			)
			(then
				(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
				(return (i32.const 0))
			)
		)
		(i32.add (global.get $guest-base) (i32.wrap_i64 (local.get $effective)))
	)

	;; Check wide guest addresses and offsets without overflow or truncation before translating to backing memory.
	(func $guest-address64
		(param $address i64)
		(param $offset i64)
		(param $width i64)
		(result i32)
		(local $limit i64)

		(local.set $limit
			(i64.mul (i64.extend_i32_u (global.get $guest-pages)) (i64.const 65536))
		)
		;; Subtraction-based checks reject overflow and permit a zero-length range at the endpoint.
		(if
			(i32.or
				(i64.gt_u (local.get $address) (local.get $limit))
				(i32.or
					(i64.gt_u (local.get $offset) (i64.sub (local.get $limit) (local.get $address)))
					(i64.gt_u
						(local.get $width)
						(i64.sub (i64.sub (local.get $limit) (local.get $address)) (local.get $offset))
					)
				)
			)
			(then
				(call $fail (i32.const M4_ERR_MEMORY_BOUNDS))
				(return (i32.const 0))
			)
		)
		(i32.add
			(global.get $guest-base)
			(i32.wrap_i64 (i64.add (local.get $address) (local.get $offset)))
		)
	)

	;; Normalize the address according to its logical memory type before checking an access immediate.
	(func $memory-address
		(param $address i64)
		(param $immediate i32)
		(param $width i32)
		(result i32)

		(call $guest-address64
			(select
				(local.get $address)
				(i64.extend_i32_u (i32.wrap_i64 (local.get $address)))
				(i32.eq (global.get $memory-type) (i32.const 2))
			)
			(i64.load (local.get $immediate))
			(i64.extend_i32_u (local.get $width))
		)
	)

	;; Let a trusted bootstrap parent hold interpreter arenas plus its child's complete guest memory.
	(func (export "enable_interpreter_backing")
		(global.set $guest-capacity (i32.const 65536))
	)

	;; Grow logical guest memory, zero new bytes, and move scratch beyond it; failure returns -1.
	(func $guest-grow
		(param $delta i32)
		(result i32)
		(local $old i32)
		(local $pages i64)
		(local $end i64)
		(local $start i32)
		(local $bytes i32)
		(local $following i32)
		(local $i i32)
		(local $record i32)

		(local.set $old (global.get $guest-pages))
		(local.set $pages
			(i64.add (i64.extend_i32_u (local.get $old)) (i64.extend_i32_u (local.get $delta)))
		)
		;; Respect both declared limits and the bounded guest-page implementation capacity.
		(if
			(i32.or
				(i64.gt_u (local.get $pages) (i64.extend_i32_u (global.get $guest-max)))
				(i64.gt_u (local.get $pages) (i64.extend_i32_u (global.get $guest-capacity)))
			)
			(then
				(return (i32.const -1))
			)
		)
		;; A zero delta retains the validated current size without touching backing memory or descriptors.
		(if (i32.eqz (local.get $delta))
			(then (return (local.get $old)))
		)
		(local.set $end
			(i64.add
				(i64.extend_i32_u (global.get $host-base))
				(i64.mul (i64.extend_i32_u (local.get $delta)) (i64.const 65536))
			)
		)
		;; Grow the backing range before moving following memories or changing any logical descriptor.
		(if (i32.eqz (call $ensure-bytes (i64.add (local.get $end) (i64.const 1024))))
			(then
				(return (i32.const -1))
			)
		)
		(local.set $start
			(i32.add (global.get $guest-base) (i32.mul (local.get $old) (i32.const 65536)))
		)
		(local.set $bytes (i32.mul (local.get $delta) (i32.const 65536)))
		(local.set $following (i32.sub (global.get $host-base) (local.get $start)))
		;; Only packed bytes belonging to following memories need relocation; the last memory has none.
		(if (local.get $following)
			(then
				(memory.copy
					(i32.add (local.get $start) (local.get $bytes))
					(local.get $start)
					(local.get $following)
				)
			)
		)
		(call $zero-bytes (local.get $start) (local.get $bytes))
		(local.set $i (i32.add (global.get $memory-index) (i32.const 1)))
		;; Packed regions after this canonical memory move together, including zero-page declarations.
		(block $done
			;; Declaration order disambiguates adjacent empty memories that share a byte base.
			(loop $memories
				(br_if $done (i32.eq (local.get $i) (global.get $memory-present)))
				(local.set $record (call $memory-record (local.get $i)))
				;; Aliases follow their canonical descriptor and do not own a separate region.
				(if
					(i32.eqz (i32.load offset=52 (local.get $record)))
					(then
						(i32.store offset=20
							(local.get $record)
							(i32.add (i32.load offset=20 (local.get $record)) (local.get $bytes))
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $memories)
			)
		)
		(global.set $guest-pages (i32.wrap_i64 (local.get $pages)))
		(i32.store offset=16
			(call $memory-record (global.get $memory-index))
			(global.get $guest-pages)
		)
		(global.set $host-base (i32.wrap_i64 (local.get $end)))
		(local.get $old)
	)

	;; Apply a resource opcode; all memory loads/stores use translated, checked guest addresses.
	(func $resource-apply
		(param $op i32)
		(param $a i64)
		(param $b i64)
		(param $immediate i32)
		(result i64)
		(local $address i32)

		;; Global reads return their persistent current value.
		(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_GET))
			(then
				(return (i64.load offset=24 (call $canonical-global-record (local.get $immediate))))
			)
		)
		;; Validated mutable globals retain writes across calls and invocations.
		(if (i32.eq (local.get $op) (i32.const M4_OP_GLOBAL_SET))
			(then
				(i64.store offset=24
					(call $canonical-global-record (local.get $immediate))
					(local.get $a)
				)
				(return (i64.const 0))
			)
		)
		;; memory.size reports logical guest pages rather than native interpreter pages.
		(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_SIZE))
			(then
				(return (i64.extend_i32_s (global.get $guest-pages)))
			)
		)
		;; memory.grow returns the previous size or -1 without trapping on a limit/allocation failure.
		(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_GROW))
			(then
				;; Wide deltas must be rejected before conversion to the physical page counter.
				(if
					(i32.and
						(i32.eq (global.get $memory-type) (i32.const 2))
						(i64.gt_u (local.get $a) (i64.const 4294967295))
					)
					(then
						(return (i64.const -1))
					)
				)
				(return (i64.extend_i32_s (call $guest-grow (i32.wrap_i64 (local.get $a)))))
			)
		)
		(local.set $address
			(call $memory-address
				(local.get $a)
				(local.get $immediate)
				(call $access-width (local.get $op))
			)
		)
		;; Do not perform a native access after a guest bounds failure.
		(if (global.get $error)
			(then
				(return (i64.const 0))
			)
		)
		;; Unaligned full-width loads are permitted regardless of the source alignment hint.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD))
			(then
				(return (i64.extend_i32_s (i32.load align=1 (local.get $address))))
			)
		)
		;; Signed byte loads extend bit seven to the full i32 result.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD8_S))
			(then
				(return (i64.extend_i32_s (i32.load8_s (local.get $address))))
			)
		)
		;; Unsigned byte loads zero-extend their result.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD8_U))
			(then
				(return (i64.extend_i32_s (i32.load8_u (local.get $address))))
			)
		)
		;; Signed halfword loads extend bit fifteen, including unaligned accesses.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD16_S))
			(then
				(return (i64.extend_i32_s (i32.load16_s align=1 (local.get $address))))
			)
		)
		;; Unsigned halfword loads zero-extend their result.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_LOAD16_U))
			(then
				(return (i64.extend_i32_s (i32.load16_u align=1 (local.get $address))))
			)
		)
		;; Full-width stores preserve all i32 bits in little-endian order.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_STORE))
			(then
				(i32.store align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Byte stores truncate the value to its low eight bits.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_STORE8))
			(then
				(i32.store8 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Halfword stores truncate the value to its low sixteen bits.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I32_STORE16))
			(then
				(i32.store16 align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Execute i64.load through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD))
			(then
				(return (i64.load align=1 (local.get $address)))
			)
		)
		;; Execute i64.load8_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD8_S))
			(then
				(return (i64.load8_s (local.get $address)))
			)
		)
		;; Execute i64.load8_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD8_U))
			(then
				(return (i64.load8_u (local.get $address)))
			)
		)
		;; Execute i64.load16_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD16_S))
			(then
				(return (i64.load16_s align=1 (local.get $address)))
			)
		)
		;; Execute i64.load16_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD16_U))
			(then
				(return (i64.load16_u align=1 (local.get $address)))
			)
		)
		;; Execute i64.load32_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD32_S))
			(then
				(return (i64.load32_s align=1 (local.get $address)))
			)
		)
		;; Execute i64.load32_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_LOAD32_U))
			(then
				(return (i64.load32_u align=1 (local.get $address)))
			)
		)
		;; Execute i64.store through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE))
			(then
				(i64.store align=1 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store8 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE8))
			(then
				(i64.store8 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store16 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE16))
			(then
				(i64.store16 align=1 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store32 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const M4_OP_I64_STORE32))
			(then
				(i64.store32 align=1 (local.get $address) (local.get $b))
			)
		)
		;; Load single precision without evaluating or canonicalizing its NaN payload.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32_LOAD))
			(then
				(return (i64.extend_i32_u (i32.load align=1 (local.get $address))))
			)
		)
		;; Store the low word of a single-precision value, including unaligned addresses.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F32_STORE))
			(then
				(i32.store align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Double precision transports all eight bits-per-byte without float arithmetic.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64_LOAD))
			(then
				(return (i64.load align=1 (local.get $address)))
			)
		)
		;; Double-precision stores preserve signed zero and NaN payload bits.
		(if (i32.eq (local.get $op) (i32.const M4_OP_F64_STORE))
			(then
				(i64.store align=1 (local.get $address) (local.get $b))
			)
		)
		(i64.const 0)
	)

	;; Return the translated guest-memory base for host inspection after a successful load.
	(func (export "guest_memory_base")
		(result i32)

		(i32.load offset=20 (call $canonical-memory-record (i32.const 0)))
	)

	;; Return the logical guest page count; it can change during an invocation.
	(func (export "guest_memory_pages")
		(result i32)

		(i32.load offset=16 (call $canonical-memory-record (i32.const 0)))
	)

	;; Distinguish an absent memory from a present zero-page memory.
	(func (export "guest_memory_present")
		(result i32)

		(global.get $memory-present)
	)

	;; Clear a backing byte range explicitly so guest growth never exposes old host scratch or state.
	(func $zero-bytes
		(param $p i32)
		(param $n i32)

		(memory.fill (local.get $p) (i32.const 0) (local.get $n))
	)

	;; Locate one memory declaration in its bounded namespace arena.
	(func $memory-record
		(param $index i32)
		(result i32)

		(i32.add (global.get $memory-arena) (i32.mul (local.get $index) (i32.const 64)))
	)

	;; Follow an import alias directly to its canonical memory descriptor.
	(func $canonical-memory-record
		(param $index i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $memory-record (local.get $index)))
		;; Aliases point directly to the first import of the same shared memory.
		(if (i32.load offset=52 (local.get $record))
			(then
				(return
					(call $memory-record (i32.sub (i32.load offset=52 (local.get $record)) (i32.const 1)))
				)
			)
		)
		(local.get $record)
	)

	;; Select one memory's logical limits and physical byte range for validation or execution.
	(func $use-memory
		(param $index i32)
		(local $record i32)

		(local.set $record (call $canonical-memory-record (local.get $index)))
		(global.set $memory-index
			(i32.div_u (i32.sub (local.get $record) (global.get $memory-arena)) (i32.const 64))
		)
		(global.set $memory-name (i32.load (local.get $record)))
		(global.set $memory-name-length (i32.load offset=4 (local.get $record)))
		(global.set $guest-min (i32.load offset=8 (local.get $record)))
		(global.set $guest-max (i32.load offset=12 (local.get $record)))
		(global.set $guest-pages (i32.load offset=16 (local.get $record)))
		(global.set $guest-base (i32.load offset=20 (local.get $record)))
		(global.set $memory-type
			(select
				(i32.const 2)
				(i32.const 1)
				(i32.eq (i32.load offset=24 (local.get $record)) (i32.const 2))
			)
		)
		(global.set $memory-max-present (i32.load offset=28 (local.get $record)))
		(global.set $memory-min64 (i64.load offset=32 (local.get $record)))
		(global.set $memory-max64 (i64.load offset=40 (local.get $record)))
		(global.set $memory-offset (i32.load offset=48 (local.get $record)))
	)

	;; Resolve a memory identifier without mixing resource or function namespaces.
	(func $find-memory
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Exhaustion produces the missing-name sentinel.
		(block $done
			;; Compare each complete identifier span in declaration order.
			(loop $names
				(br_if $done (i32.eq (local.get $i) (global.get $memory-present)))
				(local.set $record (call $memory-record (local.get $i)))
				;; Exact names match only within the memory namespace.
				(if
					;; Compare bytes only after the complete span/prefix guard succeeds.
					(if (result i32)
						(i32.eq (local.get $n) (i32.load offset=4 (local.get $record)))
						(then
							(call $equal (local.get $p) (i32.load (local.get $record)) (local.get $n))
						)
						;; An incompatible span cannot match this name or prefix.
						(else (i32.const 0))
					)
					(then
						(return (local.get $i))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $names)
			)
		)
		(i32.const -1)
	)

	;; Publish a parsed memory's complete descriptor before finalizing its import or definition.
	(func $finish-memory
		(param $index i32)
		(local $record i32)

		(local.set $record (call $memory-record (local.get $index)))
		(i32.store (local.get $record) (global.get $memory-name))
		(i32.store offset=4 (local.get $record) (global.get $memory-name-length))
		(i32.store offset=8 (local.get $record) (global.get $guest-min))
		(i32.store offset=12 (local.get $record) (global.get $guest-max))
		(i32.store offset=24 (local.get $record) (global.get $memory-type))
		(i32.store offset=28 (local.get $record) (global.get $memory-max-present))
		(i64.store offset=32 (local.get $record) (global.get $memory-min64))
		(i64.store offset=40 (local.get $record) (global.get $memory-max64))
		(i32.store offset=48 (local.get $record) (global.get $memory-offset))
		(i32.store offset=56 (local.get $record) (global.get $parsing-import))
		(call $finish-resource-declaration (i32.const 1) (local.get $index))
	)

	;; Allocate one independent auxiliary memory immediate with space for offsets, memory pairs and data targets.
	(func $new-memory-immediate
		(result i32)
		(local $record i32)

		;; Eight slots cannot overlap following branch vectors or other instruction immediates.
		(if
			(i32.gt_u (global.get $table-count) (i32.sub (i32.const M4_CAP_TABLE) (i32.const 8)))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i32.const 0))
			)
		)
		(local.set $record
			(i32.add (global.get $table-base) (i32.mul (global.get $table-count) (i32.const 4)))
		)
		(global.set $table-count (i32.add (global.get $table-count) (i32.const 8)))
		(call $zero-bytes (local.get $record) (i32.const 32))
		(local.get $record)
	)

	;; Read optional memory selectors for size, growth, fill and copy before folded operands.
	(func $memory-immediate
		(param $op i32)
		(result i32)
		(local $record i32)

		(local.set $record (call $new-memory-immediate))
		;; Explicit copy destinations must be paired with explicit sources.
		(if (call $table-reference (i32.add (local.get $record) (i32.const 8)))
			(then
				;; Copy retains its independently resolved source memory.
				(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_COPY))
					(then
						;; Incomplete memory pairs are text syntax errors.
						(if (i32.eqz (call $table-reference (i32.add (local.get $record) (i32.const 16))))
							(then
								(call $fail (i32.const M4_ERR_SYNTAX))
							)
						)
					)
				)
			)
		)
		(local.get $record)
	)

	;; Parse memory.init's data index with an optional leading memory selector.
	(func $memory-init-immediate
		(result i32)
		(local $record i32)

		(local.set $record (call $new-memory-immediate))
		;; At least the data target is required.
		(if (i32.eqz (call $table-reference (i32.add (local.get $record) (i32.const 24))))
			(then
				(call $fail (i32.const M4_ERR_SYNTAX))
				(return (local.get $record))
			)
		)
		;; With two targets, the first is the memory and the second is the data segment.
		(if (call $table-reference (i32.add (local.get $record) (i32.const 8)))
			(then
				(i64.store offset=16 (local.get $record) (i64.load offset=8 (local.get $record)))
				(i64.store offset=8 (local.get $record) (i64.load offset=24 (local.get $record)))
				(i64.store offset=24 (local.get $record) (i64.load offset=16 (local.get $record)))
				(i64.store offset=16 (local.get $record) (i64.const 0))
			)
		)
		(local.get $record)
	)

	;; Resolve an instruction's selected memories and cache their logical address widths.
	(func $resolve-memory-immediate
		(param $op i32)
		(param $record i32)
		(param $source i32)

		(i32.store offset=8
			(local.get $record)
			(call $resource-target
				(i32.const 1)
				(i32.load offset=8 (local.get $record))
				(i32.load offset=12 (local.get $record))
				(local.get $source)
			)
		)
		(i32.store offset=12 (local.get $record) (i32.const 0))
		;; Invalid indices must never become descriptor addresses.
		(if (global.get $error)
			(then
				(return)
			)
		)
		(call $use-memory (i32.load offset=8 (local.get $record)))
		;; Copy resolves and validates the source independently of the destination.
		(if (i32.eq (local.get $op) (i32.const M4_OP_MEMORY_COPY))
			(then
				(i32.store offset=16
					(local.get $record)
					(call $resource-target
						(i32.const 1)
						(i32.load offset=16 (local.get $record))
						(i32.load offset=20 (local.get $record))
						(local.get $source)
					)
				)
				(i32.store offset=20 (local.get $record) (i32.const 0))
				;; Both references must exist before reading either logical width.
				(if (global.get $error)
					(then
						(return)
					)
				)
				(global.set $memory-source-type
					(i32.load offset=24
						(call $canonical-memory-record (i32.load offset=16 (local.get $record)))
					)
				)
			)
		)
	)
