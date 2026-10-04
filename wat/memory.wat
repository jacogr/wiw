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
			(i32.or (i32.eq (local.get $op) (i32.const 150)) (i32.eq (local.get $op) (i32.const 151)))
			(then
				(return (i32.const 8))
			)
		)
		;; Single-precision accesses preserve four raw IEEE bytes.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const 148)) (i32.eq (local.get $op) (i32.const 149)))
			(then
				(return (i32.const 4))
			)
		)
		;; Full-width i64 accesses require eight bytes and allow alignments up to eight.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const 94)) (i32.eq (local.get $op) (i32.const 101)))
			(then
				(return (i32.const 8))
			)
		)
		;; Narrow i64 loads/stores still check their actual accessed width.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const 99))
				(i32.or (i32.eq (local.get $op) (i32.const 100)) (i32.eq (local.get $op) (i32.const 104)))
			)
			(then
				(return (i32.const 4))
			)
		)
		;; Halfword i64 accesses read or write two bytes.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const 97))
				(i32.or (i32.eq (local.get $op) (i32.const 98)) (i32.eq (local.get $op) (i32.const 103)))
			)
			(then
				(return (i32.const 2))
			)
		)
		;; Full i32 loads and stores access four bytes.
		(if
			(i32.or (i32.eq (local.get $op) (i32.const 53)) (i32.eq (local.get $op) (i32.const 58)))
			(then
				(return (i32.const 4))
			)
		)
		;; Sixteen-bit loads and stores access two bytes.
		(if
			(i32.or
				(i32.eq (local.get $op) (i32.const 56))
				(i32.or (i32.eq (local.get $op) (i32.const 57)) (i32.eq (local.get $op) (i32.const 60)))
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

		(i32.and
			(i32.eq (global.get $kind) (i32.const 3))
			(i32.and
				(i32.ge_u (global.get $len) (local.get $n))
				(call $equal (global.get $tok) (local.get $p) (local.get $n))
			)
		)
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
				(call $fail (i32.const 1))
				(return (i32.const 0))
			)
		)
		(call $index)
	)

	;; Parse offset then alignment; record offset as the immediate and alignment as extra metadata.
	(func $memarg
		(param $op i32)
		(result i32)
		(local $offset i32)
		(local $alignment i32)
		(local $at i32)

		(local.set $alignment (call $access-width (local.get $op)))
		;; An omitted offset defaults to zero.
		(if (call $attribute (i32.const 99) (i32.const 7))
			(then
				(local.set $offset (call $attribute-index (i32.const 7)))
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
		(local.get $offset)
	)

	;; Check resource references and mutability regardless of validation reachability.
	(func $validate-resource
		(param $op i32)
		(param $index i32)

		;; All memory instructions require the module to declare its default memory.
		(if (i32.ge_u (local.get $op) (i32.const 51))
			(then
				;; A missing memory is a validation error even for dead loads/stores.
				(if (i32.eqz (global.get $memory-present))
					(then
						(call $fail (i32.const 10))
					)
				)
				(return)
			)
		)
		;; Resolved global indices must remain inside the global table.
		(if (i32.ge_u (local.get $index) (global.get $global-count))
			(then
				(call $fail (i32.const 10))
				(return)
			)
		)
		;; global.set may only address a mutable global, including inside dead code.
		(if
			(i32.and
				(i32.eq (local.get $op) (i32.const 50))
				(i32.eqz (i32.load offset=8 (call $global-record (local.get $index))))
			)
			(then
				(call $fail (i32.const 16))
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
				(call $fail (i32.const 14))
				(return (i32.const 0))
			)
		)
		(i32.add (global.get $guest-base) (i32.wrap_i64 (local.get $effective)))
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
		(local.set $end
			(i64.add
				(i64.extend_i32_u (global.get $guest-base))
				(i64.mul (local.get $pages) (i64.const 65536))
			)
		)
		;; Leave physical room for the host's next export name/argument buffer.
		(if (i32.eqz (call $ensure-bytes (i64.add (local.get $end) (i64.const 1024))))
			(then
				(return (i32.const -1))
			)
		)
		(call $zero-bytes
			(i32.add (global.get $guest-base) (i32.mul (local.get $old) (i32.const 65536)))
			(i32.mul (local.get $delta) (i32.const 65536))
		)
		(global.set $guest-pages (i32.wrap_i64 (local.get $pages)))
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
		(if (i32.eq (local.get $op) (i32.const 49))
			(then
				(return (i64.load offset=24 (call $global-record (local.get $immediate))))
			)
		)
		;; Validated mutable globals retain writes across calls and invocations.
		(if (i32.eq (local.get $op) (i32.const 50))
			(then
				(i64.store offset=24 (call $global-record (local.get $immediate)) (local.get $a))
				(return (i64.const 0))
			)
		)
		;; memory.size reports logical guest pages rather than native interpreter pages.
		(if (i32.eq (local.get $op) (i32.const 51))
			(then
				(return (i64.extend_i32_s (global.get $guest-pages)))
			)
		)
		;; memory.grow returns the previous size or -1 without trapping on a limit/allocation failure.
		(if (i32.eq (local.get $op) (i32.const 52))
			(then
				(return (i64.extend_i32_s (call $guest-grow (i32.wrap_i64 (local.get $a)))))
			)
		)
		(local.set $address
			(call $guest-address
				(i32.wrap_i64 (local.get $a))
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
		(if (i32.eq (local.get $op) (i32.const 53))
			(then
				(return (i64.extend_i32_s (i32.load align=1 (local.get $address))))
			)
		)
		;; Signed byte loads extend bit seven to the full i32 result.
		(if (i32.eq (local.get $op) (i32.const 54))
			(then
				(return (i64.extend_i32_s (i32.load8_s (local.get $address))))
			)
		)
		;; Unsigned byte loads zero-extend their result.
		(if (i32.eq (local.get $op) (i32.const 55))
			(then
				(return (i64.extend_i32_s (i32.load8_u (local.get $address))))
			)
		)
		;; Signed halfword loads extend bit fifteen, including unaligned accesses.
		(if (i32.eq (local.get $op) (i32.const 56))
			(then
				(return (i64.extend_i32_s (i32.load16_s align=1 (local.get $address))))
			)
		)
		;; Unsigned halfword loads zero-extend their result.
		(if (i32.eq (local.get $op) (i32.const 57))
			(then
				(return (i64.extend_i32_s (i32.load16_u align=1 (local.get $address))))
			)
		)
		;; Full-width stores preserve all i32 bits in little-endian order.
		(if (i32.eq (local.get $op) (i32.const 58))
			(then
				(i32.store align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Byte stores truncate the value to its low eight bits.
		(if (i32.eq (local.get $op) (i32.const 59))
			(then
				(i32.store8 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Halfword stores truncate the value to its low sixteen bits.
		(if (i32.eq (local.get $op) (i32.const 60))
			(then
				(i32.store16 align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Execute i64.load through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 94))
			(then
				(return (i64.load align=1 (local.get $address)))
			)
		)
		;; Execute i64.load8_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 95))
			(then
				(return (i64.load8_s (local.get $address)))
			)
		)
		;; Execute i64.load8_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 96))
			(then
				(return (i64.load8_u (local.get $address)))
			)
		)
		;; Execute i64.load16_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 97))
			(then
				(return (i64.load16_s align=1 (local.get $address)))
			)
		)
		;; Execute i64.load16_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 98))
			(then
				(return (i64.load16_u align=1 (local.get $address)))
			)
		)
		;; Execute i64.load32_s through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 99))
			(then
				(return (i64.load32_s align=1 (local.get $address)))
			)
		)
		;; Execute i64.load32_u through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 100))
			(then
				(return (i64.load32_u align=1 (local.get $address)))
			)
		)
		;; Execute i64.store through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 101))
			(then
				(i64.store align=1 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store8 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 102))
			(then
				(i64.store8 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store16 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 103))
			(then
				(i64.store16 align=1 (local.get $address) (local.get $b))
			)
		)
		;; Execute i64.store32 through the checked translated guest address.
		(if (i32.eq (local.get $op) (i32.const 104))
			(then
				(i64.store32 align=1 (local.get $address) (local.get $b))
			)
		)
		;; Load single precision without evaluating or canonicalizing its NaN payload.
		(if (i32.eq (local.get $op) (i32.const 148))
			(then
				(return (i64.extend_i32_u (i32.load align=1 (local.get $address))))
			)
		)
		;; Store the low word of a single-precision value, including unaligned addresses.
		(if (i32.eq (local.get $op) (i32.const 149))
			(then
				(i32.store align=1 (local.get $address) (i32.wrap_i64 (local.get $b)))
			)
		)
		;; Double precision transports all eight bits-per-byte without float arithmetic.
		(if (i32.eq (local.get $op) (i32.const 150))
			(then
				(return (i64.load align=1 (local.get $address)))
			)
		)
		;; Double-precision stores preserve signed zero and NaN payload bits.
		(if (i32.eq (local.get $op) (i32.const 151))
			(then
				(i64.store align=1 (local.get $address) (local.get $b))
			)
		)
		(i64.const 0)
	)

	;; Return the translated guest-memory base for host inspection after a successful load.
	(func (export "guest_memory_base")
		(result i32)

		(global.get $guest-base)
	)

	;; Return the logical guest page count; it can change during an invocation.
	(func (export "guest_memory_pages")
		(result i32)

		(global.get $guest-pages)
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
