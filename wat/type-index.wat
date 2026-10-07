	;; Hash ordered parameters and results without relying on nominal reference type IDs.
	;; Reference codes share one hash token; exact recursive equality remains authoritative.
	(func $signature-hash
		(param $parameters i32)
		(param $count i32)
		(param $shape i32)
		(result i32)
		(local $hash i32)
		(local $i i32)
		(local $type i32)
		(local $results i32)

		(local.set $results (call $shape-count (local.get $shape)))
		(local.set $hash (i32.mul (i32.xor (i32.const M4_NAME_HASH_SEED) (local.get $count)) (i32.const M4_NAME_HASH_PRIME)))
		;; Finish after mixing each parameter in declaration order.
		(block $parameters-done
			;; Canonical numeric widths and vectors retain their codes; references use one common token.
			(loop $parameters
				(br_if $parameters-done (i32.eq (local.get $i) (local.get $count)))
				(local.set $type (i32.load (i32.add (local.get $parameters) (i32.mul (local.get $i) (i32.const M4_U32_BYTES)))))
				(local.set $hash
					(i32.mul (i32.xor (local.get $hash)
						(select (local.get $type) (i32.const M4_SIGNATURE_REFERENCE_TOKEN)
							(i32.or (i32.le_u (local.get $type) (i32.const 4)) (i32.eq (local.get $type) (i32.const 7)))))
						(i32.const M4_NAME_HASH_PRIME))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $parameters)
			)
		)
		(local.set $hash (i32.mul (i32.xor (local.get $hash) (local.get $results)) (i32.const M4_NAME_HASH_PRIME)))
		(local.set $i (i32.const 0))
		;; A scalar result and an equivalent singleton vector must hash identically.
		(block $results-done
			;; Mix logical result types rather than allocation-dependent shape pointers.
			(loop $results
				(br_if $results-done (i32.eq (local.get $i) (local.get $results)))
				(local.set $type (call $shape-type (local.get $shape) (local.get $i)))
				(local.set $hash
					(i32.mul (i32.xor (local.get $hash)
						(select (local.get $type) (i32.const M4_SIGNATURE_REFERENCE_TOKEN)
							(i32.or (i32.le_u (local.get $type) (i32.const 4)) (i32.eq (local.get $type) (i32.const 7)))))
						(i32.const M4_NAME_HASH_PRIME))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $results)
			)
		)
		(local.get $hash)
	)

	;; Prepend a signature to its temporary bucket, storing hash and link in spare heap metadata.
	(func $index-signature
		(param $index i32)
		(param $hash i32)
		(local $bucket i32)
		(local $record i32)

		(local.set $bucket (i32.add (global.get $fp-t-base)
			(i32.mul (i32.and (local.get $hash) (i32.const M4_SIGNATURE_BUCKET_MASK)) (i32.const M4_U32_BYTES))))
		(local.set $record (call $heap-record (local.get $index)))
		(i32.store offset=M4_SIGNATURE_HASH_OFFSET (local.get $record) (local.get $hash))
		(i32.store offset=M4_SIGNATURE_LINK_OFFSET (local.get $record) (i32.load (local.get $bucket)))
		(i32.store (local.get $bucket) (i32.add (local.get $index) (i32.const 1)))
	)

	;; Build signature buckets after literal parsing, preserving the earliest eligible declaration.
	;; Recursive groups, non-final declarations and subtypes stay outside implicit type matching.
	(func $index-declared-signatures
		(local $i i32)
		(local $s i32)

		(call $zero-bytes (global.get $fp-t-base) (i32.const M4_SIGNATURE_BUCKET_BYTES))
		(local.set $i (global.get $signature-count))
		;; Reverse insertion makes each initial bucket visit signatures in source order.
		(block $done
			;; Only canonical candidates accepted by the original scan enter this index.
			(loop $types
				(br_if $done (i32.eqz (local.get $i)))
				(local.set $i (i32.sub (local.get $i) (i32.const 1)))
				;; The existing eligibility rule preserves complete recursive-group identity.
				(if (call $implicit-heap-type (local.get $i))
					(then
						(local.set $s (call $signature (local.get $i)))
						(call $index-signature (local.get $i)
							(call $signature-hash (i32.add (local.get $s) (i32.const 32))
								(i32.load offset=8 (local.get $s)) (i32.load offset=12 (local.get $s))))
					)
				)
				(br $types)
			)
		)
	)
