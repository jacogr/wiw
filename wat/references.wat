	;; Match reference grammar keywords without using the reserved static keyword buffer.
	(func $is-ref-word
		(param $word i32)
		(result i32)

		;; Recognize the ref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 0))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the null token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 1))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 4))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.eq (global.get $len) (i32.const 4))
											(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
										)
										(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
									)
									(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 108))
								)
								(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the any token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 2))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 97))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 110))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 121))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the eq token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 3))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 2))
					(then
						(return
							(i32.and
								(i32.and
									(i32.eq (global.get $len) (i32.const 2))
									(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 113))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the i31 token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 4))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 105))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 51))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 49))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the struct token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 5))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 6))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.eq (global.get $len) (i32.const 6))
													(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 115))
												)
												(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 116))
											)
											(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 114))
										)
										(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 117))
									)
									(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 99))
								)
								(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 116))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the array token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 6))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 5))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.eq (global.get $len) (i32.const 5))
												(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 97))
											)
											(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 114))
										)
										(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 97))
								)
								(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 121))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the none token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 7))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 4))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.eq (global.get $len) (i32.const 4))
											(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
										)
										(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 111))
									)
									(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 110))
								)
								(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 101))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the nofunc token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 8))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 6))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.eq (global.get $len) (i32.const 6))
													(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
												)
												(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 111))
											)
											(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 102))
										)
										(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 117))
									)
									(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 110))
								)
								(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 99))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the noextern token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 9))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 8))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.eq (global.get $len) (i32.const 8))
															(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
														)
														(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 111))
													)
													(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 101))
												)
												(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 120))
											)
											(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 116))
										)
										(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 101))
									)
									(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 114))
								)
								(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 110))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the exn token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 10))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 101))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 120))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 110))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the noexn token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 11))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 5))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.eq (global.get $len) (i32.const 5))
												(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
											)
											(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 111))
										)
										(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 101))
									)
									(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 120))
								)
								(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 110))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the anyref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 12))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 6))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.eq (global.get $len) (i32.const 6))
													(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 97))
												)
												(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 110))
											)
											(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 121))
										)
										(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the eqref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 13))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 5))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.eq (global.get $len) (i32.const 5))
												(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 101))
											)
											(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 113))
										)
										(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the i31ref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 14))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 6))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.eq (global.get $len) (i32.const 6))
													(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 105))
												)
												(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 51))
											)
											(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 49))
										)
										(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the structref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 15))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 9))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.and
																(i32.eq (global.get $len) (i32.const 9))
																(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 115))
															)
															(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 116))
														)
														(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 114))
													)
													(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 117))
												)
												(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 99))
											)
											(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 116))
										)
										(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the arrayref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 16))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 8))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.eq (global.get $len) (i32.const 8))
															(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 97))
														)
														(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 114))
													)
													(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 114))
												)
												(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 97))
											)
											(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 121))
										)
										(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the nullref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 17))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 7))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.eq (global.get $len) (i32.const 7))
														(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
													)
													(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
												)
												(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 108))
											)
											(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
										)
										(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the nullfuncref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 18))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 11))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.and
																(i32.and
																	(i32.and
																		(i32.eq (global.get $len) (i32.const 11))
																		(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
																	)
																	(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
																)
																(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 108))
															)
															(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
														)
														(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 102))
													)
													(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 117))
												)
												(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 110))
											)
											(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 99))
										)
										(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=9 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=10 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the nullexternref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 19))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 13))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.and
																(i32.and
																	(i32.and
																		(i32.and
																			(i32.and
																				(i32.eq (global.get $len) (i32.const 13))
																				(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
																			)
																			(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
																		)
																		(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 108))
																	)
																	(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
																)
																(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 101))
															)
															(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 120))
														)
														(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 116))
													)
													(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 101))
												)
												(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 114))
											)
											(i32.eq (i32.load8_u offset=9 (global.get $tok)) (i32.const 110))
										)
										(i32.eq (i32.load8_u offset=10 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=11 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=12 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the exnref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 20))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 6))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.eq (global.get $len) (i32.const 6))
													(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 101))
												)
												(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 120))
											)
											(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 110))
										)
										(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the nullexnref token after checking its complete length.
		(if (i32.eq (local.get $word) (i32.const 21))
			(then
				;; Compare this keyword byte for byte.
				(if (i32.eq (global.get $len) (i32.const 10))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.and
													(i32.and
														(i32.and
															(i32.and
																(i32.and
																	(i32.eq (global.get $len) (i32.const 10))
																	(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 110))
																)
																(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
															)
															(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 108))
														)
														(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
													)
													(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 101))
												)
												(i32.eq (i32.load8_u offset=5 (global.get $tok)) (i32.const 120))
											)
											(i32.eq (i32.load8_u offset=6 (global.get $tok)) (i32.const 110))
										)
										(i32.eq (i32.load8_u offset=7 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=8 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=9 (global.get $tok)) (i32.const 102))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the rec composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 22))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 114))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 101))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 99))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the sub composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 23))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 115))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 117))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 98))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the final composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 24))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 5))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.eq (global.get $len) (i32.const 5))
												(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 102))
											)
											(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 105))
										)
										(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 110))
									)
									(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 97))
								)
								(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 108))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the field composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 25))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 5))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.and
											(i32.and
												(i32.eq (global.get $len) (i32.const 5))
												(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 102))
											)
											(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 105))
										)
										(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 101))
									)
									(i32.eq (i32.load8_u offset=3 (global.get $tok)) (i32.const 108))
								)
								(i32.eq (i32.load8_u offset=4 (global.get $tok)) (i32.const 100))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the i8 composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 26))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 2))
					(then
						(return
							(i32.and
								(i32.and
									(i32.eq (global.get $len) (i32.const 2))
									(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 105))
								)
								(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 56))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		;; Recognize the i16 composite type grammar keyword.
		(if (i32.eq (local.get $word) (i32.const 27))
			(then
				;; Check length before comparing keyword bytes.
				(if (i32.eq (global.get $len) (i32.const 3))
					(then
						(return
							(i32.and
								(i32.and
									(i32.and
										(i32.eq (global.get $len) (i32.const 3))
										(i32.eq (i32.load8_u offset=0 (global.get $tok)) (i32.const 105))
									)
									(i32.eq (i32.load8_u offset=1 (global.get $tok)) (i32.const 49))
								)
								(i32.eq (i32.load8_u offset=2 (global.get $tok)) (i32.const 54))
							)
						)
					)
				)
				(return (i32.const 0))
			)
		)
		(i32.const 0)
	)

	;; Locate a deferred reference type descriptor; low ID bits retain nullability.
	(func $reference-type-record
		(param $type i32)
		(result i32)

		(i32.add
			(global.get $reference-type-base)
			(i32.mul
				(i32.shr_u (i32.sub (local.get $type) (i32.const 64)) (i32.const 1))
				(i32.const 32)
			)
		)
	)

	;; Intern a source-backed or numeric heap type, allowing named forward references.
	(func $intern-reference-type
		(param $value i32)
		(param $length i32)
		(param $source i32)
		(param $nonnull i32)
		(result i32)
		(local $i i32)
		(local $record i32)

		;; Stop after every existing heap reference has been checked.
		(block $done
			;; Equivalent numeric indices or names share one deferred descriptor.
			(loop $types
				(br_if $done (i32.eq (local.get $i) (global.get $reference-type-count)))
				(local.set $record
					(call $reference-type-record
						(i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 2)))
					)
				)
				;; Names compare by text; numeric indices compare by value.
				(if
					;; Length mismatches cannot reuse either a named or numeric descriptor.
					(if (result i32)
						(i32.eq (local.get $length) (i32.load offset=4 (local.get $record)))
						(then
							;; Named type uses compare their identifier bytes; numeric uses compare indices.
							(if (result i32) (local.get $length)
								(then
									(call $equal (local.get $value) (i32.load (local.get $record)) (local.get $length))
								)
								;; Numeric type uses do not read source strings.
								(else
									(i32.eq (local.get $value) (i32.load (local.get $record)))
								)
							)
						)
						;; Different identifier lengths retain separate descriptors.
						(else (i32.const 0))
					)
					(then
						(return
							(i32.add
								(i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 2)))
								(local.get $nonnull)
							)
						)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
		;; Reject exhausted type-use storage before creating a descriptor.
		(if (i32.ge_u (local.get $i) (i32.const 4096))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i32.const 0))
			)
		)
		(local.set $record
			(call $reference-type-record
				(i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 2)))
			)
		)
		(i32.store (local.get $record) (local.get $value))
		(i32.store offset=4 (local.get $record) (local.get $length))
		(i32.store offset=8 (local.get $record) (local.get $source))
		(i32.store offset=12 (local.get $record) (i32.const -1))
		(global.set $reference-type-count (i32.add (local.get $i) (i32.const 1)))
		(i32.add
			(i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 2)))
			(local.get $nonnull)
		)
	)

	;; Resolve a reference's declared heap type after the full type namespace has been parsed.
	(func $reference-heap (export "type_heap")
		(param $type i32)
		(result i32)
		(local $record i32)
		(local $index i32)

		;; Abstract types have no declaration index.
		(if (i32.lt_u (local.get $type) (i32.const 64))
			(then
				(return (i32.const -1))
			)
		)
		(local.set $record (call $reference-type-record (local.get $type)))
		(local.set $index (i32.load offset=12 (local.get $record)))
		;; Deferred names are resolved only once and retain the original error position.
		(if (i32.eq (local.get $index) (i32.const -1))
			(then
				(local.set $index
					(call $type-target
						(i32.load (local.get $record))
						(i32.load offset=4 (local.get $record))
						(i32.load offset=8 (local.get $record))
					)
				)
				(i32.store offset=12 (local.get $record) (local.get $index))
			)
		)
		(local.get $index)
	)

	;; Resolve every heap type use, including references in otherwise unreachable declarations.
	(func $resolve-reference-types
		(local $i i32)

		;; Complete when all parsed type uses have been resolved.
		(block $done
			;; This pass also rejects unknown heap types in unused function signatures.
			(loop $types
				(br_if $done (global.get $error))
				(br_if $done (i32.eq (local.get $i) (global.get $reference-type-count)))
				(drop
					(call $reference-heap (i32.add (i32.const 64) (i32.mul (local.get $i) (i32.const 2))))
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $types)
			)
		)
	)

	;; Determine whether a concrete type is a reference rather than a numeric value.
	(func $is-reference
		(param $type i32)
		(result i32)

		(i32.or
			(i32.ge_u (local.get $type) (i32.const 16))
			(i32.or
				(i32.or (i32.eq (local.get $type) (i32.const 5)) (i32.eq (local.get $type) (i32.const 6)))
				(i32.or (i32.eq (local.get $type) (i32.const 8)) (i32.eq (local.get $type) (i32.const 9)))
			)
		)
	)

	;; Report reference nullability, keeping the original funcref and externref IDs stable.
	(func $reference-nonnull (export "type_nonnull")
		(param $type i32)
		(result i32)

		;; Deferred and additional abstract reference types encode nullability in bit zero.
		(if (i32.ge_u (local.get $type) (i32.const 16))
			(then
				(return (i32.and (local.get $type) (i32.const 1)))
			)
		)
		(i32.or (i32.eq (local.get $type) (i32.const 8)) (i32.eq (local.get $type) (i32.const 9)))
	)

	;; Convert a reference type to its non-null variant without changing its heap type.
	(func $reference-nonnull-type
		(param $type i32)
		(result i32)

		;; Original nullable reference IDs retain their historical scalar codes.
		(if (i32.eq (local.get $type) (i32.const 5))
			(then
				(return (i32.const 8))
			)
		)
		;; External reference nullability uses the parallel abstract type.
		(if (i32.eq (local.get $type) (i32.const 6))
			(then
				(return (i32.const 9))
			)
		)
		(i32.or (local.get $type) (i32.const 1))
	)

	;; Match two declared heap types by their position and complete ordered recursive groups.
	(func $heap-type-equal
		(param $a i32)
		(param $b i32)
		(result i32)
		(local $ha i32)
		(local $hb i32)
		(local $ga i32)
		(local $gb i32)
		(local $count i32)
		(local $pair i32)
		(local $i i32)
		(local $equal i32)
		(local $in-a i32)
		(local $in-b i32)

		;; Invalid type indices cannot be converted into heap descriptor pointers.
		(if
			(i32.or
				(i32.ge_u (local.get $a) (global.get $signature-count))
				(i32.ge_u (local.get $b) (global.get $signature-count))
			)
			(then
				(return (i32.const 0))
			)
		)
		;; References into the current recursive groups compare by relative member index.
		(if (global.get $type-comparison-depth)
			(then
				(local.set $pair
					(i32.add
						(global.get $type-comparison-base)
						(i32.mul (i32.sub (global.get $type-comparison-depth) (i32.const 1)) (i32.const 8))
					)
				)
				(local.set $ga (i32.load (local.get $pair)))
				(local.set $gb (i32.load offset=4 (local.get $pair)))
				(local.set $count (i32.load offset=8 (call $heap-record (local.get $ga))))
				(local.set $in-a (i32.lt_u (i32.sub (local.get $a) (local.get $ga)) (local.get $count)))
				(local.set $in-b (i32.lt_u (i32.sub (local.get $b) (local.get $gb)) (local.get $count)))
				;; Bound group members cannot equal a free reference to an earlier group.
				(if (i32.or (local.get $in-a) (local.get $in-b))
					(then
						(return
							(i32.and
								(i32.and (local.get $in-a) (local.get $in-b))
								(i32.eq (i32.sub (local.get $a) (local.get $ga)) (i32.sub (local.get $b) (local.get $gb)))
							)
						)
					)
				)
			)
		)
		;; The same declaration is canonically identical outside a relative group comparison.
		(if (i32.eq (local.get $a) (local.get $b))
			(then
				(return (i32.const 1))
			)
		)
		(local.set $ha (call $heap-record (local.get $a)))
		(local.set $hb (call $heap-record (local.get $b)))
		(local.set $ga (i32.load offset=4 (local.get $ha)))
		(local.set $gb (i32.load offset=4 (local.get $hb)))
		(local.set $count (i32.load offset=8 (local.get $ha)))
		;; Group size and member position both form part of a canonical recursive type.
		(if
			(i32.or
				(i32.ne (local.get $count) (i32.load offset=8 (local.get $hb)))
				(i32.ne (i32.sub (local.get $a) (local.get $ga)) (i32.sub (local.get $b) (local.get $gb)))
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Earlier group references form a bounded acyclic dependency graph.
		(if (i32.ge_u (global.get $type-comparison-depth) (i32.const 1024))
			(then
				(call $fail (i32.const M4_ERR_RESOURCE_LIMIT))
				(return (i32.const 0))
			)
		)
		(local.set $pair
			(i32.add
				(global.get $type-comparison-base)
				(i32.mul (global.get $type-comparison-depth) (i32.const 8))
			)
		)
		(i32.store (local.get $pair) (local.get $ga))
		(i32.store offset=4 (local.get $pair) (local.get $gb))
		(global.set $type-comparison-depth
			(i32.add (global.get $type-comparison-depth) (i32.const 1))
		)
		(local.set $equal (i32.const 1))
		;; Finish after all group members have matched structurally.
		(block $done
			;; Composite kinds, finality, parents and ordered fields are canonical group contents.
			(loop $members
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; Any unequal member makes the complete recursive groups unequal.
				(if
					(i32.eqz
						(call $heap-member-equal
							(i32.add (local.get $ga) (local.get $i))
							(i32.add (local.get $gb) (local.get $i))
						)
					)
					(then
						(local.set $equal (i32.const 0))
						(br $done)
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $members)
			)
		)
		(global.set $type-comparison-depth
			(i32.sub (global.get $type-comparison-depth) (i32.const 1))
		)
		(local.get $equal)
	)

	;; Check value subtyping, allowing a non-null function reference where a nullable reference is expected.
	(func $type-compatible
		(param $actual i32)
		(param $expected i32)
		(result i32)
		(local $a i32)
		(local $e i32)

		;; Equal codes and polymorphic unknowns need no heap lookup.
		(if
			(i32.or (i32.eq (local.get $actual) (local.get $expected)) (i32.eqz (local.get $actual)))
			(then
				(return (i32.const 1))
			)
		)
		;; Numeric values cannot enter the reference hierarchy.
		(if
			(i32.eqz
				(i32.and
					(call $is-reference (local.get $actual))
					(call $is-reference (local.get $expected))
				)
			)
			(then
				(return (i32.const 0))
			)
		)
		;; Nullability is independent from heap subtyping.
		(if
			(i32.and
				(call $reference-nonnull (local.get $expected))
				(i32.eqz (call $reference-nonnull (local.get $actual)))
			)
			(then
				(return (i32.const 0))
			)
		)
		(local.set $a (call $reference-category (local.get $actual)))
		(local.set $e (call $reference-category (local.get $expected)))
		;; Function, external and exception bottom heap types refine their own hierarchy only.
		(if
			(i32.or
				(i32.and (i32.eq (local.get $a) (i32.const 28)) (i32.eq (local.get $e) (i32.const 5)))
				(i32.or
					(i32.and (i32.eq (local.get $a) (i32.const 30)) (i32.eq (local.get $e) (i32.const 6)))
					(i32.and (i32.eq (local.get $a) (i32.const 34)) (i32.eq (local.get $e) (i32.const 32)))
				)
			)
			(then
				(return (i32.const 1))
			)
		)
		;; The internal bottom heap refines all internal aggregate and equality heap types.
		(if
			(i32.and
				(i32.eq (local.get $a) (i32.const 26))
				(i32.and
					(i32.ge_u (local.get $e) (i32.const 16))
					(i32.le_u (local.get $e) (i32.const 26))
				)
			)
			(then
				(return (i32.const 1))
			)
		)
		;; Concrete references refine their corresponding abstract heap category.
		(if (i32.lt_u (local.get $expected) (i32.const 64))
			(then
				;; Equal abstract heaps differ only in nullability, already checked above.
				(if (i32.eq (local.get $a) (local.get $e))
					(then
						(return (i32.const 1))
					)
				)
				;; Equality references include i31, struct and array values.
				(if
					(i32.and
						(i32.eq (local.get $e) (i32.const 18))
						(i32.and
							(i32.ge_u (local.get $a) (i32.const 20))
							(i32.le_u (local.get $a) (i32.const 24))
						)
					)
					(then
						(return (i32.const 1))
					)
				)
				;; Any internal reference includes equality references and all their refinements.
				(if
					(i32.and
						(i32.eq (local.get $e) (i32.const 16))
						(i32.and
							(i32.ge_u (local.get $a) (i32.const 18))
							(i32.le_u (local.get $a) (i32.const 24))
						)
					)
					(then
						(return (i32.const 1))
					)
				)
				(return (i32.const 0))
			)
		)
		;; Concrete heap types compare their declarations rather than source spelling.
		(if
			(i32.and
				(i32.ge_u (local.get $actual) (i32.const 64))
				(i32.ge_u (local.get $expected) (i32.const 64))
			)
			(then
				(return
					(call $heap-type-subtype
						(call $reference-heap (local.get $actual))
						(call $reference-heap (local.get $expected))
					)
				)
			)
		)
		(i32.const 0)
	)

	;; Check structural type equality independently from nullable reference subtyping.
	(func $type-equal
		(param $a i32)
		(param $b i32)
		(result i32)

		;; Declared reference equality uses relative recursive-group references even when raw codes coincide.
		(if
			(i32.and
				(i32.ge_u (local.get $a) (i32.const 64))
				(i32.ge_u (local.get $b) (i32.const 64))
			)
			(then
				(return
					(i32.and
						(i32.eq (call $reference-nonnull (local.get $a)) (call $reference-nonnull (local.get $b)))
						(call $heap-type-equal
							(call $reference-heap (local.get $a))
							(call $reference-heap (local.get $b))
						)
					)
				)
			)
		)
		(i32.and
			(call $type-compatible (local.get $a) (local.get $b))
			(call $type-compatible (local.get $b) (local.get $a))
		)
	)

	;; Recognize an explicit parenthesized reference type without changing the parser cursor.
	(func $reference-type-token
		(result i32)
		(local $open i32)
		(local $result i32)

		;; Bare reference aliases are already unambiguous atoms.
		(if
			(i32.or
				(call $is-word (i32.const 3845) (i32.const 7))
				(call $is-word (i32.const 3893) (i32.const 9))
			)
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 12))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 13))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 14))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 15))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 16))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 17))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 18))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 19))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 20))
			(then
				(return (i32.const 1))
			)
		)
		;; Nullable abstract aliases are complete reference type tokens.
		(if (call $is-ref-word (i32.const 21))
			(then
				(return (i32.const 1))
			)
		)
		;; Only reference declaration openings need lookahead.
		(if (i32.eq (global.get $kind) (i32.const 1))
			(then
				(local.set $open (global.get $tok))
				(call $next)
				(local.set $result (call $is-ref-word (i32.const 0)))
				(global.set $pos (local.get $open))
				(call $next)
			)
		)
		(local.get $result)
	)

	;; Map internal reference types to the host's existing opaque value categories.
	(func $value-kind (export "value_kind")
		(param $type i32)
		(result i32)
		(local $category i32)

		;; Internal and exception references use separate opaque host categories.
		(if
			(i32.and
				(i32.ge_u (local.get $type) (i32.const 16))
				(i32.lt_u (local.get $type) (i32.const 64))
			)
			(then
				(local.set $category (i32.and (local.get $type) (i32.const -2)))
				;; Function bottom types retain the function reference host representation.
				(if (i32.eq (local.get $category) (i32.const 28))
					(then
						(return (i32.const 5))
					)
				)
				;; External bottom types retain the external reference host representation.
				(if (i32.eq (local.get $category) (i32.const 30))
					(then
						(return (i32.const 6))
					)
				)
				;; Exception references remain distinct from GC internal references.
				(if
					(i32.or
						(i32.eq (local.get $category) (i32.const 32))
						(i32.eq (local.get $category) (i32.const 34))
					)
					(then
						(return (i32.const 9))
					)
				)
				(return (i32.const 8))
			)
		)
		;; Aggregate references share the opaque internal-reference host category.
		(if (i32.ge_u (local.get $type) (i32.const 64))
			(then
				;; Only function heap declarations use the function reference host representation.
				(if (i32.ne (call $reference-category (local.get $type)) (i32.const 5))
					(then
						(return (i32.const 8))
					)
				)
			)
		)
		;; Typed function references use the function reference host representation.
		(if
			(i32.or
				(i32.ge_u (local.get $type) (i32.const 64))
				(i32.eq (local.get $type) (i32.const 8))
			)
			(then
				(return (i32.const 5))
			)
		)
		;; A non-null external reference still carries an opaque external host value.
		(if (i32.eq (local.get $type) (i32.const 9))
			(then
				(return (i32.const 6))
			)
		)
		(local.get $type)
	)

	;; Derive the precise non-null function reference type from its completed signature.
	(func $function-reference-type
		(param $function i32)
		(result i32)
		(local $i i32)
		(local $use i32)
		(local $type i32)

		(local.set $use (call $function-type (local.get $function)))
		;; Parsing may inspect unfinished declarations; only completed module types can use cached values.
		(if (global.get $function-types-resolved)
			(then
				(local.set $type (i32.load offset=20 (local.get $use)))
				;; A nonzero reference type belongs to this declaration in the current load generation.
				(if (local.get $type)
					(then
						(return (local.get $type))
					)
				)
			)
		)
		;; An explicit function type use preserves its declared heap type.
		(if (i32.load offset=12 (local.get $use))
			(then
				(local.set $i
					(call $type-target
						(i32.load (local.get $use))
						(i32.load offset=4 (local.get $use))
						(i32.load offset=8 (local.get $use))
					)
				)
			)
			;; Inline signatures were interned before body validation.
			(else
				;; Complete at the matching implicit or explicit structural signature.
				(block $done
					;; Search only the declared type namespace, excluding anonymous indirect call records.
					(loop $types
						(br_if $done (i32.eq (local.get $i) (global.get $signature-count)))
						(br_if $done
							(i32.and
								(call $implicit-heap-type (local.get $i))
								(call $function-matches (local.get $function) (call $signature (local.get $i)))
							)
						)
						(local.set $i (i32.add (local.get $i) (i32.const 1)))
						(br $types)
					)
				)
			)
		)
		(local.set $type
			(call $intern-reference-type (local.get $i) (i32.const 0) (global.get $tok) (i32.const 1))
		)
		;; Cache matched completed types; parsing and unmatched foreign signatures remain uncached.
		(if
			(i32.and
				(i32.and (global.get $function-types-resolved) (i32.eqz (global.get $error)))
				(i32.lt_u (local.get $i) (global.get $signature-count))
			)
			(then
				(i32.store offset=20 (local.get $use) (local.get $type))
			)
		)
		(local.get $type)
	)

	;; Return a function local's abstract initialization level slot.
	(func $local-init-slot
		(param $index i32)
		(result i32)

		(i32.add (global.get $local-init-base) (i32.mul (local.get $index) (i32.const 4)))
	)

	;; Discard local assignments introduced by the arm or block that is ending.
	(func $reset-local-initialization
		(local $i i32)
		(local $count i32)

		(local.set $count (i32.load offset=20 (call $function (global.get $current-function))))
		;; Finish after examining every declared local.
		(block $done
			;; Only assignments made at this scope's level are rolled back.
			(loop $locals
				(br_if $done (i32.eq (local.get $i) (local.get $count)))
				;; Assignments made only within this control region do not survive its exit.
				(if
					(i32.eq (i32.load (call $local-init-slot (local.get $i))) (global.get $control-count))
					(then
						(i32.store (call $local-init-slot (local.get $i)) (i32.const 0))
					)
				)
				(local.set $i (i32.add (local.get $i) (i32.const 1)))
				(br $locals)
			)
		)
	)

	;; Expose complete heap parameter counts to the trusted host for reference import compatibility.
	(func (export "heap_params")
		(param $index i32)
		(result i32)

		(i32.load offset=8 (call $signature (local.get $index)))
	)

	;; Expose one declared heap parameter type without erasing nullability or the heap identity.
	(func (export "heap_param_type")
		(param $index i32)
		(param $slot i32)
		(result i32)

		(i32.load offset=32
			(i32.add (call $signature (local.get $index)) (i32.mul (local.get $slot) (i32.const 4)))
		)
	)

	;; Expose a declared function heap's ordered result count.
	(func (export "heap_results")
		(param $index i32)
		(result i32)

		(call $shape-count (i32.load offset=12 (call $signature (local.get $index))))
	)

	;; Expose one declared function heap result type for cross-instance reference compatibility.
	(func (export "heap_result_type")
		(param $index i32)
		(param $slot i32)
		(result i32)

		(call $shape-type
			(i32.load offset=12 (call $signature (local.get $index)))
			(local.get $slot)
		)
	)

	;; Classify the abstract hierarchy of a reference independently from its nullability.
	(func $reference-category
		(param $type i32)
		(result i32)

		;; Declared heap types currently describe functions; aggregate descriptors extend this classification.
		(if (i32.ge_u (local.get $type) (i32.const 64))
			(then
				(return (call $heap-category (call $reference-heap (local.get $type))))
			)
		)
		;; Historical function reference IDs have one abstract heap.
		(if
			(i32.or (i32.eq (local.get $type) (i32.const 5)) (i32.eq (local.get $type) (i32.const 8)))
			(then
				(return (i32.const 5))
			)
		)
		;; Historical external reference IDs have one abstract heap.
		(if
			(i32.or (i32.eq (local.get $type) (i32.const 6)) (i32.eq (local.get $type) (i32.const 9)))
			(then
				(return (i32.const 6))
			)
		)
		(i32.and (local.get $type) (i32.const -2))
	)

	;; Expose a completed function's declared heap type for trusted cross-instance linking.
	(func (export "function_heap_type")
		(param $index i32)
		(result i32)

		(call $function-reference-type (local.get $index))
	)

	;; Expose raw reference hierarchy information without losing abstract heap distinctions.
	(func (export "reference_category")
		(param $type i32)
		(result i32)

		(call $reference-category (local.get $type))
	)

	;; Expose one complete composite descriptor to the trusted host.
	(func (export "heap_info")
		(param $index i32)
		(result i32)

		(call $heap-record (local.get $index))
	)

	;; Expose one complete aggregate field descriptor to the trusted host.
	(func (export "field_info")
		(param $index i32)
		(result i32)

		(call $field-record (local.get $index))
	)
