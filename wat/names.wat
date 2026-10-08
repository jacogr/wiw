	;; Locate an exact identifier or its vacant slot in a bounded, generation-tagged name table.
	;; Capacities exceed their namespace limits, so every probe sequence reaches a vacant slot.
	(func $name-slot
		(param $table i32)
		(param $mask i32)
		(param $generation i32)
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $hash i32)
		(local $cursor i32)
		(local $slot i32)

		(local.set $hash (i32.const M4_NAME_HASH_SEED))
		;; Bounded word reads mix long identifiers without visiting every byte separately.
		(block $words-done
			;; Fold high bits into the bucket bits after each word to spread shared prefixes.
			(loop $words
				(br_if $words-done
					(i32.lt_u (i32.sub (local.get $n) (local.get $cursor)) (i32.const M4_WORD_BYTES))
				)
				(local.set $hash
					(i32.mul
						(i32.xor (local.get $hash) (i32.load (i32.add (local.get $p) (local.get $cursor))))
						(i32.const M4_NAME_HASH_PRIME)
					)
				)
				(local.set $hash (i32.xor (local.get $hash) (i32.shr_u (local.get $hash) (i32.const M4_NAME_HASH_FOLD_SHIFT))))
				(local.set $cursor (i32.add (local.get $cursor) (i32.const M4_WORD_BYTES)))
				(br $words)
			)
		)
		;; Stop after hashing exactly the identifier's source bytes, including UTF-8 bytes.
		(block $hashed
			;; Byte tails preserve exact source bounds; equality below remains authoritative despite collisions.
			(loop $bytes
				(br_if $hashed (i32.eq (local.get $cursor) (local.get $n)))
				(local.set $hash
					(i32.mul
						(i32.xor (local.get $hash) (i32.load8_u (i32.add (local.get $p) (local.get $cursor))))
						(i32.const M4_NAME_HASH_PRIME)
					)
				)
				(local.set $cursor (i32.add (local.get $cursor) (i32.const 1)))
				(br $bytes)
			)
		)
		;; Linear probing wraps within this table and treats older generations as vacant.
		(loop $probe
			(local.set $slot
				(i32.add (local.get $table)
					(i32.shl (i32.and (local.get $hash) (local.get $mask)) (i32.const M4_NAME_INDEX_SLOT_SHIFT)))
			)
			;; A different namespace generation has no live entry at this slot.
			(if (i32.ne (i32.load offset=M4_NAME_INDEX_GENERATION_OFFSET (local.get $slot)) (local.get $generation))
				(then (return (local.get $slot)))
			)
			;; Equal lengths are necessary before comparing complete identifier byte spans.
			(if (i32.eq (i32.load offset=M4_NAME_INDEX_LENGTH_OFFSET (local.get $slot)) (local.get $n))
				(then
					;; Hash collisions never identify a different spelling as this name.
					(if (call $equal (i32.load (local.get $slot)) (local.get $p) (local.get $n))
						(then (return (local.get $slot)))
					)
				)
			)
			(local.set $hash (i32.add (local.get $hash) (i32.const 1)))
			(br $probe)
		)
		(unreachable)
	)

	;; Append newly declared names to an index, then return the exact requested index or -1.
	;; Anonymous records are skipped; previously indexed names preserve their original index.
	(func $indexed-name
		(param $base i32)
		(param $stride i32)
		(param $count i32)
		(param $indexed i32)
		(param $table i32)
		(param $mask i32)
		(param $generation i32)
		(param $p i32)
		(param $n i32)
		(result i32)
		(local $record i32)
		(local $slot i32)
		(local $length i32)

		;; Catch up only once for each declaration, including declarations after forward uses.
		(block $ready
			;; Walk the unindexed suffix without changing the source-backed declaration records.
			(loop $append
				(br_if $ready (i32.eq (local.get $indexed) (local.get $count)))
				(local.set $record (i32.add (local.get $base) (i32.mul (local.get $indexed) (local.get $stride))))
				(local.set $length (i32.load offset=4 (local.get $record)))
				;; Anonymous declarations are accessible by numeric index only.
				(if (local.get $length)
					(then
						(local.set $slot (call $name-slot (local.get $table) (local.get $mask)
							(local.get $generation) (i32.load (local.get $record)) (local.get $length)))
						;; Preserve the first declaration if malformed input presents a duplicate.
						(if (i32.ne (i32.load offset=M4_NAME_INDEX_GENERATION_OFFSET (local.get $slot)) (local.get $generation))
							(then
								(i64.store (local.get $slot) (i64.load (local.get $record)))
								(i32.store offset=M4_NAME_INDEX_VALUE_OFFSET (local.get $slot) (local.get $indexed))
								(i32.store offset=M4_NAME_INDEX_GENERATION_OFFSET (local.get $slot) (local.get $generation))
							)
						)
					)
				)
				(local.set $indexed (i32.add (local.get $indexed) (i32.const 1)))
				(br $append)
			)
		)
		(local.set $slot (call $name-slot (local.get $table) (local.get $mask)
			(local.get $generation) (local.get $p) (local.get $n)))
		;; An absent spelling reaches a vacant slot without changing the table.
		(if (result i32) (i32.eq (i32.load offset=M4_NAME_INDEX_GENERATION_OFFSET (local.get $slot)) (local.get $generation))
			(then (i32.load offset=M4_NAME_INDEX_VALUE_OFFSET (local.get $slot)))
			;; Missing names preserve the existing resolver's -1 sentinel.
			(else (i32.const -1))
		)
	)
