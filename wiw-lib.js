/**
 * Bootstrap interpreter bytes or a compiled interpreter module, never guest source.
 * @typedef {Uint8Array<ArrayBuffer> | WebAssembly.Module} BootstrapBinary
 */

/**
 * Platform execution context; Node preserves it across awaits, browsers use synchronous scopes.
 * @template T
 * @typedef {object} RuntimeContext
 * @property {() => T | undefined} getStore
 * @property {<R>(store: T, callback: () => R) => R} run
 */

/**
 * Execution ownership and event-loop scheduling supplied by the frontend.
 * @typedef {object} RuntimeServices
 * @property {RuntimeContext<number>} invocationContext
 * @property {RuntimeContext<CallbackScope>} callbackContext
 * @property {() => Promise<void>} yieldTask
 */

/**
 * Private identity for a generation-bound guest heap or exception reference.
 * @typedef {{type: number, bits: bigint, generation: number}} OpaqueReference
 */

/**
 * Scalar calling convention used when forwarding an ABI export selected by name.
 * @typedef {(...args: AbiValue[]) => AbiValue | void} AbiForwarder
 */

/**
 * Hosted exports are populated dynamically before wrapping the complete interpreter ABI.
 * @typedef {InterpreterExports & Record<string, AbiExport | AbiForwarder>} HostedExports
 */

/**
 * Source context retained until a diagnostic needs coordinates.
 * @typedef {{format: 'wat' | 'wasm' | undefined, length: number, text: string | undefined}} DiagnosticSource
 */

/**
 * Cooperative settings after filling the default dispatch quantum.
 * @typedef {CooperativeOptions & {quantum: number}} ResolvedCooperativeOptions
 */

/**
 * Resource export location and kind resolved from guest export metadata.
 * @typedef {{index: number, kind: number}} ResourceExport
 */

/**
 * Generation-independent kind names, including the zero/void slot.
 * @typedef {Readonly<Record<number, ValueTypeName | null>>} ScalarNames
 */

/**
 * Core interpreter export signatures used by the JavaScript adapter.
 * @typedef {object} InterpreterExports
 * @property {WebAssembly.Memory} memory
 * @property {(p: number, n: number) => number} load
 * @property {() => number} initialize
 * @property {(p: number, n: number, args: number, count: number) => number} invoke
 * @property {() => number} error_code
 * @property {() => number} error_offset
 * @property {() => number} host_base
 * @property {() => number} result_count
 * @property {(fuel: number) => void} set_fuel
 * @property {(fuel: bigint) => void} set_fuel64
 * @property {() => number} guest_memory_base
 * @property {() => number} guest_memory_pages
 * @property {() => number} guest_memory_present
 * @property {(p: number, n: number) => number} get_global
 * @property {(p: number, n: number, value: number) => number} set_global
 * @property {() => number} import_count
 * @property {(index: number) => number} import_info
 * @property {(index: number) => number} function_params
 * @property {(index: number) => number} function_results
 * @property {(p: number, n: number) => number} export_function
 * @property {() => number} pending_import
 * @property {() => number} pending_args
 * @property {(value: number, failed: number) => number} resume
 * @property {(delta: number) => number} grow_guest_memory
 * @property {(p: number, n: number, args: number, count: number) => bigint} invoke64
 * @property {(value: bigint, failed: number) => bigint} resume64
 * @property {(slot: number) => number} result_type
 * @property {(index: number, slot: number) => number} function_param_type
 * @property {(index: number, slot: number) => number} function_result_type
 * @property {(p: number, n: number) => number} global_type
 * @property {() => number} argument_high_base
 * @property {() => number} pending_high_args
 * @property {() => number} result_high_base
 * @property {() => number} result_base
 * @property {(p: number, n: number) => bigint} global_high
 * @property {(p: number, n: number, value: bigint) => number} set_global_high
 * @property {(p: number, n: number) => bigint} get_global64
 * @property {(p: number, n: number, value: bigint) => number} set_global64
 * @property {() => number} load_initializing
 * @property {(index: number, include_results: number) => number} function_signature
 * @property {(type: number) => number} type_heap
 * @property {(type: number) => number} type_nonnull
 * @property {(type: number) => number} value_kind
 * @property {(index: number) => number} heap_params
 * @property {(index: number, slot: number) => number} heap_param_type
 * @property {(index: number) => number} heap_results
 * @property {(index: number, slot: number) => number} heap_result_type
 * @property {(index: number) => number} function_heap_type
 * @property {(type: number) => number} reference_category
 * @property {(index: number) => number} heap_info
 * @property {(index: number) => number} field_info
 * @property {(value: bigint) => number} object_type
 * @property {(value: bigint, live: number) => void} gc_pin
 * @property {() => void} collect_garbage
 * @property {() => number} gc_live_bytes
 * @property {(index: number) => number} tag_info
 * @property {(index: number) => number} tag_type
 * @property {() => number} tag_count
 * @property {(index: number, identity: number) => void} bind_tag
 * @property {() => bigint} exception_reference
 * @property {(value: bigint) => number} exception_info
 * @property {(identity: number, count: number, args: number, refs_low: bigint, refs_high: bigint) => bigint} import_exception
 * @property {(identity: number, count: number, args: number, refs: number) => bigint} import_exception_bits
 * @property {(value: bigint) => bigint} resume_exception
 * @property {() => number} result_info
 * @property {() => number} pending_result_capacity
 * @property {() => number} exports_count
 * @property {(index: number) => number} export_info
 * @property {(index: number) => number} global_info
 * @property {() => number} memory_min
 * @property {() => number} memory_max
 * @property {() => number} table_count
 * @property {(index: number, value: bigint) => number} table_accepts
 * @property {(index: number, slot: number, value: bigint) => number} tag_accepts
 * @property {(index: number, delta: number, value: bigint) => number} grow_host_table
 * @property {(index: number) => number} table_size
 * @property {(index: number) => number} table_max
 * @property {(index: number) => number} table_type
 * @property {(index: number) => number} table_base
 * @property {(index: number, size: number, maximum: number) => number} bind_guest_table
 * @property {(index: number, canonical: number) => void} alias_guest_table
 * @property {(index: number, delta: number) => number} grow_guest_table
 * @property {(pages: number, maximum: number, entries: number, table_maximum: number) => number} prepare_resource_imports
 * @property {(count: number, result: number, types: number, slot: number) => number} foreign_function
 * @property {(index: number, args: number, count: number) => bigint} invoke_index64
 * @property {() => number} segments_ready
 * @property {(index: number) => number} function_info
 * @property {(index: number, types: number, count: number) => number} foreign_results
 * @property {() => number} memory_address_type
 * @property {(index: number) => number} table_address_type
 * @property {(index: number) => number} memory_width
 * @property {(index: number) => number} memory_minimum
 * @property {(index: number) => number} memory_maximum
 * @property {(index: number) => number} memory_base
 * @property {(index: number) => number} memory_pages
 * @property {(index: number, pages: number, maximum: number) => number} bind_guest_memory
 * @property {(index: number, canonical: number) => void} alias_guest_memory
 * @property {(index: number, delta: number) => number} grow_memory
 * @property {(index: number) => number} table_info
 * @property {(p: number, n: number) => number} load_binary
 * @property {(index: number, canonical: number) => void} alias_guest_global
 * @property {() => void} enable_interpreter_backing
 * @property {(kind: number, value: number) => number} configure_capacity
 * @property {(functions: number, exports: number, globals: number, calls: number, pages: number) => number} configure_limits
 * @property {(enabled: number) => void} validation_only
 * @property {(quantum: number) => void} set_execution_quantum
 * @property {() => number} execution_paused
 * @property {() => bigint} resume_execution
 * @property {() => void} cancel_execution
 * @property {(index: number) => number} begin_reentry
 * @property {() => number} end_reentry
 */

/**
 * Typed forwarding signature and provider liveness metadata.
 * @typedef {object} FunctionMetadata
 * @property {number[]} params
 * @property {number | number[] | undefined} [results]
 * @property {() => boolean | number} valid
 * @property {TypeDescription | undefined} [descriptor]
 * @property {((args: RawValue[]) => RawResult) | undefined} [raw]
 * @property {((args: RawValue[]) => Promise<RawResult>) | undefined} [rawAsync]
 * @property {(() => FunctionReference) | undefined} [reference]
 */

/**
 * Resolved host function import and its guest argument/result signature.
 * @typedef {object} ImportBinding
 * @property {string} module
 * @property {string} name
 * @property {number[]} params
 * @property {number | number[] | undefined} [results]
 * @property {Function} callback
 */

/**
 * Host callback namespaces indexed by guest module and field names.
 * @typedef {Record<string, HostNamespace>} HostImports
 */

/**
 * Public guest value type names; externrefs may contain any JavaScript value.
 * @typedef {'i32' | 'i64' | 'f32' | 'f64' | 'v128' | 'funcref' | 'externref' | 'anyref' | 'exnref'} ValueTypeName
 */

/**
 * Host-shareable global kinds; GC and exception values retain guest instance ownership.
 * @typedef {Exclude<ValueTypeName, 'anyref' | 'exnref'>} HostValueTypeName
 */

/**
 * Logical memory/table address width.
 * @typedef {'i32' | 'i64'} AddressType
 */

/**
 * Nullable element types supported by host-created tables.
 * @typedef {'funcref' | 'externref'} TableElement
 */

/**
 * Guest WAT text, UTF-8 bytes or binary Wasm bytes selected by the loading API.
 * @typedef {string | Uint8Array} GuestSource
 */

/**
 * Native interpreter ABI scalar argument or result.
 * @typedef {number | bigint} AbiValue
 */

/**
 * A callable native interpreter export with scalar ABI values.
 * @typedef {InterpreterExports[Exclude<keyof InterpreterExports, "memory">]} AbiFunction
 */

/**
 * Memory or callable values exposed by the interpreter module.
 * @typedef {WebAssembly.Memory | AbiFunction} AbiExport
 */

/**
 * Decoded guest callback; opaque externrefs prevent a narrower universal value type.
 * @typedef {(...args: unknown[]) => unknown} HostCallback
 */

/**
 * Asynchronous decoded guest callback.
 * @typedef {(...args: unknown[]) => Promise<unknown>} AsyncHostCallback
 */

/**
 * One raw result slot or an ordered multivalue result vector.
 * @typedef {RawValue | RawValue[]} RawResult
 */

/**
 * Internal result kind code (zero for void) or multivalue kind codes.
 * @typedef {number | number[]} NumericResults
 */

/**
 * Guest resource index, exported name or opaque resource handle.
 * @typedef {number | string | ResourceHandle} ResourceSelector
 */

/**
 * Opaque tag identity used to construct and inspect guest exceptions.
 * @typedef {ResourceHandle & {kind: 'tag'}} TagHandle
 */

/**
 * Guest exports keyed by field name.
 * @typedef {Record<string, Function | ResourceHandle>} HostNamespace
 */

/**
 * Operation phase captured by a structured interpreter error.
 * @typedef {'load' | 'validate' | 'link' | 'initialize' | 'invoke' | 'access' | 'request'} DiagnosticPhase
 */

/**
 * Raw scalar/vector bits or an opaque reference slot; void results have a null type.
 * @typedef {object} RawValue
 * @property {ValueTypeName | null} type
 * @property {bigint | undefined} [bits]
 * @property {unknown | undefined} [value]
 * @property {string | null | undefined} [heap]
 */

/**
 * Opaque shared memory/global/table/tag binding.
 * @typedef {object} ResourceHandle
 * @property {'memory' | 'global' | 'table' | 'tag'} kind
 */

/**
 * Host memory/table size and logical address options.
 * @typedef {object} StorageOptions
 * @property {number | undefined} [initial]
 * @property {number | undefined} [maximum]
 * @property {AddressType | undefined} [address]
 */

/**
 * Checked physical sizes and internal logical address code.
 * @typedef {object} StorageLimits
 * @property {number} initial
 * @property {number} maximum
 * @property {number} addressType
 */

/**
 * Host global type and mutability descriptor.
 * @typedef {object} GlobalOptions
 * @property {HostValueTypeName} value
 * @property {boolean | undefined} [mutable]
 */

/**
 * Host table descriptor including its nullable element type.
 * @typedef {StorageOptions & {element?: TableElement}} TableOptions
 */

/**
 * Internal scalar/reference kind and its structural type descriptor.
 * @typedef {object} HostResourceType
 * @property {number} kind
 * @property {TypeDescription} descriptor
 */

/**
 * Host-owned byte storage with checked access and zero-filled growth.
 * @typedef {object} HostMemory
 * @property {'memory'} kind
 * @property {number} pages
 * @property {AddressType} address
 * @property {number | undefined} maximum
 * @property {(offset: number | bigint, length: number) => Uint8Array} read
 * @property {(offset: number | bigint, bytes: Uint8Array) => void} write
 * @property {(delta: number | bigint) => number} grow
 */

/**
 * Host-owned typed global with decoded and raw value access.
 * @typedef {object} HostGlobal
 * @property {'global'} kind
 * @property {HostValueTypeName} type
 * @property {boolean} mutable
 * @property {unknown} value
 * @property {() => RawValue} getRaw
 * @property {(slot: RawValue) => void} setRaw
 */

/**
 * Host-owned reference entries with checked element access and growth.
 * @typedef {object} HostTable
 * @property {'table'} kind
 * @property {number} length
 * @property {AddressType} address
 * @property {TableElement} element
 * @property {number | undefined} maximum
 * @property {(index: number | bigint) => unknown} get
 * @property {(index: number | bigint, value: unknown) => void} set
 * @property {(delta: number | bigint, value?: unknown) => number} grow
 */

/**
 * Resolved internal function signature, optionally including its function index.
 * @typedef {object} NumericSignature
 * @property {number[]} params
 * @property {NumericResults | undefined} [results]
 * @property {number | undefined} [index]
 */

/**
 * Internal export signature with its resolved, required function index.
 * @typedef {NumericSignature & {index: number}} IndexedSignature
 */

/**
 * Decoded export signature; null denotes a void result.
 * @typedef {object} PublicSignature
 * @property {ValueTypeName[]} params
 * @property {ValueTypeName | ValueTypeName[] | null} result
 */

/**
 * Decoded tag payload signature.
 * @typedef {object} TagSignature
 * @property {ValueTypeName[]} params
 */

/**
 * Numeric or nullable/nonnull reference kind with an optional heap graph.
 * @typedef {object} TypeDescription
 * @property {number} kind
 * @property {boolean | undefined} [nonnull]
 * @property {number | HeapType | undefined} [heap]
 */

/**
 * Structural recursive heap definition retaining group identity and ancestors.
 * @typedef {object} HeapType
 * @property {number} kind
 * @property {number} final
 * @property {number} position
 * @property {number | undefined} [index]
 * @property {HeapType | number | null} parent
 * @property {ReadonlyArray<HeapType>} group
 * @property {ReadonlyArray<TypeDescription>} params
 * @property {ReadonlyArray<TypeDescription>} results
 * @property {ReadonlyArray<HeapField>} fields
 */

/**
 * Aggregate field type and mutability code.
 * @typedef {object} HeapField
 * @property {TypeDescription} type
 * @property {number} mutable
 */

/**
 * Paired recursive groups used while comparing structural types.
 * @typedef {Array<[ReadonlyArray<HeapType>, ReadonlyArray<HeapType>]>} HeapContexts
 */

/**
 * Provider-owned function identity and typed forwarding callback.
 * @typedef {object} FunctionReference
 * @property {object} owner
 * @property {number} index
 * @property {HostCallback} callback
 * @property {NumericSignature} signature
 */

/**
 * Private shared resource snapshot and provider liveness check.
 * @typedef {ResourceBase & (MemoryState | GlobalState | TableState | TagState)} ResourceState
 */

/**
 * Provider liveness and optional published handle shared by all resource kinds.
 * @typedef {object} ResourceBase
 * @property {() => boolean | number} valid
 * @property {ResourceHandle | undefined} [handle]
 */

/**
 * Shared memory image and its declared growth limits.
 * @typedef {{kind: 1, addressType: number, maximum: number, pages: number, bytes: Uint8Array}} MemoryState
 */

/**
 * Shared global bits or retained reference identity.
 * @typedef {{kind: 2, type: number, descriptor: TypeDescription, mutable: number, bits: bigint, value?: unknown}} GlobalState
 */

/**
 * Shared table entries and their reference/address constraints.
 * @typedef {{kind: 3, type: number, descriptor: TypeDescription, addressType: number, maximum: number, entries: unknown[], hostOwned?: boolean}} TableState
 */

/**
 * Stable tag identity and payload signature.
 * @typedef {{kind: 4, identity: number, descriptor: TypeDescription}} TagState
 */

/**
 * Guest resource slot and its current shared publication authority.
 * @typedef {object} ResourceBinding
 * @property {number} index
 * @property {ResourceState} state
 * @property {boolean} publishable
 */

/**
 * Private retained tag identity, typed raw payload and decoded values.
 * @typedef {object} ExceptionPayload
 * @property {number} identity
 * @property {ReadonlyArray<number>} params
 * @property {ReadonlyArray<RawValue>} args
 * @property {ReadonlyArray<unknown>} values
 */

/**
 * Validated exception payload and tag identity comparison.
 * @typedef {object} ExceptionInspection
 * @property {ExceptionPayload} data
 * @property {boolean} matches
 */

/**
 * Module/field name of a guest host import.
 * @typedef {object} ImportIdentity
 * @property {string} module
 * @property {string} name
 */

/**
 * Recorded source coordinate, with line/column available only for original WAT.
 * @typedef {object} DiagnosticLocation
 * @property {'wat' | 'wasm' | 'generated-wat'} format
 * @property {number} byteOffset
 * @property {number | undefined} [line]
 * @property {number | undefined} [column]
 */

/**
 * Stable structured interpreter error metadata.
 * @typedef {object} DiagnosticDetails
 * @property {string | undefined} [code]
 * @property {number | undefined} [status]
 * @property {DiagnosticPhase | undefined} [phase]
 * @property {'wat' | 'wasm' | undefined} [sourceFormat]
 * @property {number | undefined} [byteOffset]
 * @property {DiagnosticLocation | undefined} [location]
 * @property {ImportIdentity | undefined} [import]
 */

/**
 * JSON diagnostic payload without source text, stack traces or arbitrary causes.
 * @typedef {DiagnosticDetails & {name: string, message: string}} SerializableDiagnostic
 */

/**
 * Opt-in async dispatch quantum and optional cancellation signal.
 * @typedef {object} CooperativeOptions
 * @property {number | undefined} [quantum]
 * @property {AbortSignal | undefined} [signal]
 */

/**
 * Supported instance and parent resource budget names.
 * @typedef {'functions' | 'exports' | 'globals' | 'callFrames' | 'memoryPages' | 'externalReferences' | 'forwardingDepth' | 'instructions' | 'operands' | 'controls' | 'syntaxDepth' | 'auxiliarySlots' | 'imports' | 'types' | 'indirectTypes' | 'referenceTypes' | 'fields' | 'tags' | 'memories' | 'tables' | 'tableEntries' | 'dataSegments' | 'elementSegments' | 'elementEntries' | 'dataBytes' | 'resultShapes' | 'gcHeapBytes' | 'gcMapBytes' | 'gcTemporaries' | 'binaryTextBytes' | 'typeComparisonDepth' | 'parameters' | 'results' | 'locals' | 'floatLiteralBytes'} LimitName
 */

/**
 * Complete validated instance resource capacities.
 * @typedef {Record<LimitName, number>} ResourceLimits
 */

/**
 * Factory capacities and optional self-hosted source/parent overrides.
 * @typedef {object} InterpreterOptions
 * @property {Partial<ResourceLimits> | undefined} [limits]
 * @property {Partial<ResourceLimits> | undefined} [parentLimits]
 * @property {number | bigint | undefined} [parentFuel]
 * @property {GuestSource | undefined} [source]
 */

/**
 * Private backing origin, growth delegate and validated capacities.
 * @typedef {object} BackendOptions
 * @property {number | undefined} [memoryOffset]
 * @property {((required: number) => void) | undefined} [ensureMemory]
 * @property {ResourceLimits | undefined} [limits]
 * @property {RuntimeServices} runtime
 */

/**
 * Private interpreter ABI, backing origin and forwarding-depth policy.
 * @typedef {object} RuntimeBackend
 * @property {InterpreterExports} exports
 * @property {number} memoryOffset
 * @property {boolean} countsForwardingDepth
 */

/**
 * Current operation and its snapshotted cooperative configuration.
 * @typedef {object} InvocationState
 * @property {DiagnosticPhase} phase
 * @property {CooperativeOptions | undefined} [cooperative]
 */

/**
 * Boxed async completion keeping Promise externrefs opaque until public return.
 * @typedef {object} InvocationResult
 * @property {unknown} value
 */

/**
 * Active callback ownership and completion obligations for nested guest calls.
 * @typedef {object} CallbackScope
 * @property {RuntimeBackend} backend
 * @property {InvocationState} invocation
 * @property {boolean} asynchronous
 * @property {boolean} active
 * @property {Set<Promise<InvocationResult>>} children
 * @property {CallbackScope | undefined} [parent]
 */

/**
 * Public interpreter loading, execution, resource and lifetime operations.
 * @typedef {object} InterpreterApi
 * @property {number} generation
 * @property {(source: GuestSource, binarySource?: boolean) => InterpreterApi} validate
 * @property {(source: GuestSource, imports?: HostImports, binarySource?: boolean, asynchronous?: boolean) => void | Promise<void>} load
 * @property {(source: GuestSource, imports?: HostImports) => Promise<void>} loadAsync
 * @property {(bytes: Uint8Array, imports?: HostImports) => Promise<void>} loadBinaryAsync
 * @property {(bytes: Uint8Array, imports?: HostImports) => void} loadBinary
 * @property {(name: string, ...args: unknown[]) => unknown} invoke
 * @property {(name: string, ...args: unknown[]) => Promise<unknown>} invokeAsync
 * @property {(name: string, ...args: RawValue[]) => Promise<RawResult>} invokeRawAsync
 * @property {(name: string, ...args: RawValue[]) => RawResult} invokeRaw
 * @property {() => number} collectGarbage
 * @property {(name: string) => PublicSignature} signature
 * @property {(name: string) => HostCallback} exportFunction
 * @property {(name: string) => AsyncHostCallback} exportFunctionAsync
 * @property {() => HostNamespace} exportNamespaceAsync
 * @property {(asynchronous?: boolean) => HostNamespace} exportNamespace
 * @property {(name: string) => ValueTypeName} globalType
 * @property {(name: string) => unknown} getGlobal
 * @property {(name: string, value: unknown) => void} setGlobal
 * @property {(offset: number | bigint, length: number, memory?: ResourceSelector) => Uint8Array} readMemory
 * @property {(offset: number | bigint, bytes: Uint8Array, memory?: ResourceSelector) => void} writeMemory
 * @property {(memory?: ResourceSelector) => AddressType} memoryType
 * @property {(memory?: ResourceSelector) => number} memoryPages
 * @property {(pages: number | bigint, memory?: ResourceSelector) => number} growMemory
 * @property {(tag?: ResourceSelector) => TagHandle} getTag
 * @property {(tag?: ResourceSelector) => TagSignature} tagSignature
 * @property {(tag: ResourceSelector, ...args: unknown[]) => WiwException} createException
 * @property {(tag: ResourceSelector, ...args: RawValue[]) => WiwException} createExceptionRaw
 * @property {(table?: ResourceSelector) => number} tableSize
 * @property {(index: number | bigint, table?: ResourceSelector) => unknown} getTable
 * @property {(index: number | bigint, value: unknown, table?: ResourceSelector) => void} setTable
 * @property {(entries: number | bigint, value?: unknown, table?: ResourceSelector) => number} growTable
 * @property {(options?: CooperativeOptions | null) => InterpreterApi} setCooperativeExecution
 * @property {(limit: number) => void} setFuel
 * @property {(limit: bigint) => void} setFuel64
 */

const messages = [
  '',
  'invalid syntax',
  'unsupported feature',
  'integer out of range',
  'unknown export',
  'invalid buffer',
  'resource limit',
  'invalid operand stack',
  'divide by zero',
  'integer overflow',
  'invalid or duplicate reference',
  'argument mismatch',
  'exhausted fuel',
  'executed unreachable',
  'memory out of bounds',
  'invalid memory limits',
  'immutable global',
  'interpreter error',
  'export kind mismatch',
  'invalid alignment',
  'host import failed',
  'invalid resume',
  'invocation already suspended',
  'host value type mismatch',
  'undefined element',
  'indirect call type mismatch',
  'invalid table limits',
  'element out of bounds',
  'invalid conversion to integer',
  'instance not initialized',
  'table out of bounds',
  'null reference',
  'cast failure',
  'array out of bounds',
  'uncaught exception',
  'guest execution aborted'
];
// Stable symbolic names mirror the interpreter ABI independently of message wording.
const errorCodes = [
  'SUCCESS',
  'SYNTAX',
  'UNSUPPORTED',
  'INTEGER_RANGE',
  'UNKNOWN_EXPORT',
  'INVALID_BUFFER',
  'RESOURCE_LIMIT',
  'OPERAND_STACK',
  'DIVIDE_BY_ZERO',
  'INTEGER_OVERFLOW',
  'INVALID_REFERENCE',
  'ARGUMENT_MISMATCH',
  'EXHAUSTED_FUEL',
  'UNREACHABLE',
  'MEMORY_BOUNDS',
  'MEMORY_LIMITS',
  'IMMUTABLE_GLOBAL',
  'INTERPRETER',
  'EXPORT_KIND',
  'ALIGNMENT',
  'HOST_IMPORT',
  'INVALID_RESUME',
  'SUSPENDED_REENTRY',
  'HOST_VALUE_TYPE',
  'UNDEFINED_ELEMENT',
  'INDIRECT_TYPE',
  'TABLE_LIMITS',
  'ELEMENT_BOUNDS',
  'INVALID_CONVERSION',
  'NOT_INITIALIZED',
  'TABLE_BOUNDS',
  'NULL_REFERENCE',
  'CAST_FAILURE',
  'ARRAY_BOUNDS',
  'UNCAUGHT_EXCEPTION',
  'ABORTED'
];

export class WiwError extends Error {
  /**
   * Snapshot diagnostic fields so recovery and guest reload cannot change an earlier error.
   *
   * @param {string} message
   * @param {DiagnosticDetails} [details]
   * @param {ErrorOptions} [options]
   * @constructor
   */
  constructor(message, details = {}, options = {}) {
    super(message, options);

    this.name = 'WiwError';

    // Declare diagnostic fields before locking their snapshot values below.
    /** @readonly @type {DiagnosticDetails["code"]} */
    this.code = undefined;
    /** @readonly @type {DiagnosticDetails["status"]} */
    this.status = undefined;
    /** @readonly @type {DiagnosticDetails["phase"]} */
    this.phase = undefined;
    /** @readonly @type {DiagnosticDetails["sourceFormat"]} */
    this.sourceFormat = undefined;
    /** @readonly @type {DiagnosticDetails["byteOffset"]} */
    this.byteOffset = undefined;
    /** @readonly @type {DiagnosticDetails["location"]} */
    this.location = undefined;
    /** @readonly @type {DiagnosticDetails["import"]} */
    this.import = undefined;

    // Keep diagnostic fields read-only and freeze nested coordinate/import records.
    for (const field of /** @type {const} */ ([
      'code',
      'status',
      'phase',
      'sourceFormat',
      'byteOffset',
      'location',
      'import'
    ])) {
      const value = details[field];

      Object.defineProperty(this, field, {
        value: value && typeof value === 'object' ? Object.freeze({ ...value }) : value,
        enumerable: true,
        writable: false,
        configurable: false
      });
    }
  }

  /**
   * Serialize metadata without copying guest source or traversing arbitrary host callback causes.
   *
   * @returns {SerializableDiagnostic}
   */
  toJSON() {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      status: this.status,
      phase: this.phase,
      sourceFormat: this.sourceFormat,
      byteOffset: this.byteOffset,
      location: this.location,
      import: this.import
    };
  }
}

let nextTagIdentity = 1;
/** @type {WeakMap<object, ExceptionPayload>} */
const exceptionTypes = new WeakMap();
export class WiwException extends Error {
  /**
   * Create the host error used to carry an uncaught tagged guest exception.
   *
   * @constructor
   */
  constructor() {
    super('uncaught guest exception');

    this.name = 'WiwException';
  }

  /**
   * Compare live tag identity rather than matching payload signatures.
   *
   * @param {TagHandle} tag
   * @returns {boolean}
   */
  is(tag) {
    return exceptionData(this, tag).matches;
  }

  /**
   * Read a decoded exception argument after checking its tag and index.
   *
   * @param {TagHandle} tag
   * @param {number} index
   * @returns {unknown}
   */
  getArg(tag, index) {
    return exceptionArgument(this, tag, index, false);
  }

  /**
   * Read an exception argument while preserving its raw value bits.
   *
   * @param {TagHandle} tag
   * @param {number} index
   * @returns {RawValue}
   */
  getArgRaw(tag, index) {
    return /** @type {RawValue} */ (exceptionArgument(this, tag, index, true));
  }
}

// Typed forwarding bindings retain the provider's signature and load generation.
/** @type {WeakMap<Function, FunctionMetadata>} */
const functionTypes = new WeakMap();
/** @type {WeakMap<object, ResourceState>} */
const resourceTypes = new WeakMap();

/**
 * Exception payload snapshots remain private; inspection never touches guest scratch or frame state.
 *
 * @param {WiwException} exception
 * @param {TagHandle} tag
 * @returns {ExceptionInspection}
 */
function exceptionData(exception, tag) {
  const data = exceptionTypes.get(exception),
    state = resourceTypes.get(tag);

  // Reject exception objects that have no retained guest payload.
  if (!data) throw new Error('uninitialized wiw exception');

  // Require a tag handle before comparing exception identities.
  if (!state || state.kind !== 4) throw new Error('exception inspection requires a wiw tag');

  // Prevent inspection through a tag from a previous guest generation.
  if (!state.valid()) throw new Error('stale tag binding');

  return { data, matches: data.identity === state.identity };
}

/**
 * Check the tag and bounds before returning an exception payload slot.
 *
 * @param {WiwException} exception
 * @param {TagHandle} tag
 * @param {number} index
 * @param {boolean} raw
 * @returns {unknown}
 */
function exceptionArgument(exception, tag, index, raw) {
  const { data, matches } = exceptionData(exception, tag);

  // Prevent reading a payload through an unrelated tag with a similar signature.
  if (!matches) throw new Error('exception tag mismatch');

  // Check the argument index before accessing the retained payload.
  if (!Number.isInteger(index) || index < 0 || index >= data.args.length)
    throw new Error('exception argument index out of bounds');

  return raw ? { ...data.args[index] } : data.values[index];
}

/**
 * Host-defined tags carry a structural signature and an identity independent of any guest load.
 *
 * @param {ValueTypeName[]} [parameters]
 * @returns {TagHandle}
 */
export function createTag(parameters = []) {
  // Require an ordered list of tag parameter types.
  if (!Array.isArray(parameters)) throw new Error('tag parameters must be an array');

  // Keep the tag arity representable by the guest ABI.
  if (parameters.length > 65535) throw new Error('too many tag parameters (maximum 65535)');

  const kinds = { i32: 1, i64: 2, f32: 3, f64: 4, funcref: 5, externref: 6, v128: 7, anyref: 8, exnref: 9 };
  /** @type {Partial<Record<ValueTypeName, number>>} */
  const roots = { funcref: 5, externref: 6, anyref: 16, exnref: 32 };
  // Validate each tag parameter name and retain its reference-type constraints.
  const params = Array.from(
    parameters,
    /**
     * Describe one public tag parameter and its nullable reference constraints.
     *
     * @param {ValueTypeName} name
     * @returns {TypeDescription}
     */
    (name) => {
      // Reject parameter names that the interpreter cannot encode.
      if (typeof name !== 'string' || !Object.hasOwn(kinds, name))
        throw new Error(`unsupported tag parameter type ${String(name)}`);

      return Object.freeze(
        Object.hasOwn(roots, name)
          ? { kind: kinds[name], nonnull: false, heap: /** @type {number} */ (roots[name]) }
          : { kind: kinds[name] }
      );
    }
  );
  /** @type {HeapType} */
  const heap = {
    kind: 0,
    final: 1,
    position: 0,
    parent: null,
    group: [],
    params: Object.freeze(params),
    results: Object.freeze([]),
    fields: Object.freeze([])
  };

  heap.group = Object.freeze([heap]);

  Object.freeze(heap);

  const handle = Object.freeze({ kind: 'tag' });

  resourceTypes.set(handle, {
    kind: 4,
    identity: nextTagIdentity++,

    /**
     * Host-defined tags remain valid independently of guest module reloads.
     *
     * @returns {boolean}
     */
    valid: () => true,
    handle,
    descriptor: Object.freeze({ kind: 5, nonnull: true, heap })
  });

  return handle;
}

/**
 * Validate host resource descriptors without silently accepting misspelled or unsupported options.
 *
 * @param {object} options
 * @param {string[]} allowed
 * @param {string} label
 * @returns {void}
 */
function hostResourceOptions(options, allowed, label) {
  // Descriptor fields must come from an object rather than positional scalar coercion.
  if (!options || typeof options !== 'object' || Array.isArray(options))
    throw new Error(`${label} descriptor must be an object`);

  // Reject unsupported resource modes, including shared memory while threads remain unavailable.
  for (const name of Object.keys(options)) {
    // Keep unknown options visible rather than allocating a resource with different semantics.
    if (!allowed.includes(name)) throw new Error(`unknown ${label} option ${name}`);
  }
}

/**
 * Validate physically bounded initial/maximum sizes and retain the declared logical address width.
 *
 * @param {StorageOptions} options
 * @param {number} capacity
 * @param {string} label
 * @returns {StorageLimits}
 */
function hostResourceLimits(options, capacity, label) {
  const { initial = 0, maximum, address = 'i32' } = options;

  // Both address widths use bounded physical storage; the width still controls import matching and BigInt access.
  if (address !== 'i32' && address !== 'i64') throw new Error(`${label} address must be i32 or i64`);

  // Never narrow or round a descriptor size before checking its physical representation.
  if (!Number.isInteger(initial) || initial < 0 || initial > capacity)
    throw new Error(`invalid ${label} initial size`);

  // A declared maximum must accommodate the initial resource and fit the supported physical ceiling.
  if (maximum !== undefined && (!Number.isInteger(maximum) || maximum < initial || maximum > capacity))
    throw new Error(`invalid ${label} maximum`);

  return { initial, maximum: maximum ?? -1, addressType: address === 'i64' ? 2 : 1 };
}

/**
 * Check an index or offset before narrowing a memory64/table64 BigInt to the physical host range.
 *
 * @param {number | bigint} value
 * @param {number} addressType
 * @param {number} limit
 * @param {string} label
 * @returns {number}
 */
function hostResourceIndex(value, addressType, limit, label) {
  // BigInt selectors are reserved for resources declared with 64-bit addressing.
  if (typeof value === 'bigint') {
    // Prevent memory32/table32 access from quietly adopting a different host address convention.
    if (addressType !== 2) throw new Error(`BigInt ${label} requires 64-bit addressing`);

    // The logical bound must be checked before conversion to Number.
    if (value < 0n || value > BigInt(limit)) throw new Error(`${label} out of bounds`);

    return Number(value);
  }

  // Reject unsafe or fractional selectors instead of letting array indexing coerce them.
  if (!Number.isSafeInteger(value) || value < 0 || value > limit) throw new Error(`${label} out of bounds`);

  return value;
}

/**
 * Preserve unsigned growth requests and report physically oversized memory64/table64 deltas without wrapping.
 *
 * @param {number | bigint} value
 * @param {number} addressType
 * @returns {number}
 */
function hostResourceDelta(value, addressType) {
  // A valid logical i64 delta can exceed the physical backing capacity and must fail growth rather than wrap.
  if (typeof value === 'bigint') {
    // Require the declared address width to agree with a BigInt growth request.
    if (addressType !== 2) throw new Error('BigInt growth requires 64-bit addressing');

    // Invalid logical deltas throw; valid but physically oversized ones return a failure through grow().
    if (value < 0n || value > (1n << 64n) - 1n) throw new Error('growth must be an unsigned i64 integer');

    return value > 0xffffffffn ? Infinity : Number(value);
  }

  // Number growth uses the same unsigned i32 convention as the interpreter's host growth API.
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff)
    throw new Error('growth must be an unsigned i32 integer');

  return value;
}

/**
 * Create a host-owned memory import with copied byte access and atomic, zero-filled growth.
 *
 * @param {StorageOptions} [options]
 * @returns {HostMemory}
 */
export function createMemory(options = {}) {
  hostResourceOptions(options, ['initial', 'maximum', 'address'], 'memory');

  const { initial, maximum, addressType } = hostResourceLimits(options, 65536, 'memory');
  /** @type {ResourceState & {kind: 1}} */
  const state = {
    kind: 1,
    pages: initial,
    maximum,
    addressType,
    bytes: new Uint8Array(initial * 65536),
    /**
     * Host-owned storage has no provider generation to invalidate when a guest reloads.
     *
     * @returns {boolean}
     */
    valid: () => true
  };

  /**
   * Check the entire byte span before copying or changing any memory bytes.
   *
   * @param {number | bigint} offset
   * @param {number} length
   * @returns {number}
   */
  function range(offset, length) {
    const start = hostResourceIndex(offset, addressType, state.bytes.length, 'memory offset');

    // Check length without addition so an oversized endpoint cannot overflow the bounds calculation.
    if (!Number.isSafeInteger(length) || length < 0 || length > state.bytes.length - start)
      throw new Error('memory out of bounds');

    return start;
  }

  const handle = Object.freeze({
    kind: 'memory',
    /**
     * Expose the current logical page count without publishing a mutable backing view.
     *
     * @returns {number}
     */
    get pages() {
      return state.pages;
    },
    /**
     * Retain the descriptor width even though physical page counts are bounded Numbers.
     *
     * @returns {AddressType}
     */
    get address() {
      return addressType === 2 ? 'i64' : 'i32';
    },
    /**
     * Distinguish an omitted maximum from a declared physical growth limit.
     *
     * @returns {number | undefined}
     */
    get maximum() {
      return maximum === -1 ? undefined : maximum;
    },
    /**
     * Return independent bytes so callers cannot retain stale views across guest writes or growth.
     *
     * @param {number | bigint} offset
     * @param {number} length
     * @returns {Uint8Array}
     */
    read(offset, length) {
      const at = range(offset, length);

      return state.bytes.slice(at, at + length);
    },
    /**
     * Validate the complete destination before publishing a host memory update.
     *
     * @param {number | bigint} offset
     * @param {Uint8Array} bytes
     * @returns {void}
     */
    write(offset, bytes) {
      // Accept byte arrays without coercing arbitrary iterables or numeric values.
      if (!(bytes instanceof Uint8Array)) throw new Error('memory bytes must be a Uint8Array');

      state.bytes.set(bytes, range(offset, bytes.length));
    },
    /**
     * Allocate and copy before changing size so failed growth preserves all existing storage.
     *
     * @param {number | bigint} delta
     * @returns {number}
     */
    grow(delta) {
      const old = state.pages,
        next = old + hostResourceDelta(delta, addressType);

      // Respect declared limits and the interpreter's memory32 physical backing ceiling.
      if (next > 65536 || (maximum !== -1 && next > maximum)) return -1;

      // A no-op grow preserves the current allocation and returns its existing size.
      if (next === old) return old;

      let bytes;

      // Keep allocation failure separate from committed resource state.
      try {
        bytes = new Uint8Array(next * 65536);

        bytes.set(state.bytes);
      } catch (error) {
        // Treat physical allocation exhaustion as failed growth rather than partial mutation.
        if (error instanceof RangeError) return -1;

        throw error;
      }

      state.bytes = bytes;
      state.pages = next;

      return old;
    }
  });

  state.handle = handle;

  resourceTypes.set(handle, state);

  return handle;
}

/**
 * Describe the host-shareable scalar, vector and nullable function/external reference kinds.
 *
 * @param {ValueTypeName} name
 * @returns {HostResourceType}
 */
function hostResourceType(name) {
  const kinds = { i32: 1, i64: 2, f32: 3, f64: 4, funcref: 5, externref: 6, v128: 7 };

  // Managed GC and exception objects retain instance ownership and are not manufactured by these host factories.
  if (!Object.hasOwn(kinds, name)) throw new Error(`unsupported host resource type ${String(name)}`);

  const kind = kinds[/** @type {HostValueTypeName} */ (name)];

  return {
    kind,
    descriptor: Object.freeze(kind === 5 || kind === 6 ? { kind, nonnull: false, heap: kind } : { kind })
  };
}

/**
 * Validate a function handle before retaining its typed forwarding reference in a host table or global.
 *
 * @param {unknown} value
 * @returns {FunctionReference | null}
 */
function hostFunctionReference(value) {
  // Nullable host function resources use the same null entry representation as guest tables.
  if (value === null) return null;

  const metadata = typeof value === 'function' ? functionTypes.get(value) : undefined;

  // Ordinary JS callbacks and stale guest functions lack a live declared guest signature.
  if (!metadata?.reference || !metadata.valid())
    throw new Error('value must be a live wiw function reference or null');

  return /** @type {FunctionReference} */ (metadata.reference());
}

/**
 * Encode exact numeric bits without allocating a guest instance or borrowing guest scratch memory.
 *
 * @param {unknown} value
 * @param {number} type
 * @returns {bigint}
 */
function hostGlobalBits(value, type) {
  // Keep vectors as raw 128-bit patterns, accepting the same signed/unsigned spellings as invocation arguments.
  if (type === 7) {
    // Reject values whose conversion would silently discard vector bits.
    if (typeof value !== 'bigint' || value < -(1n << 127n) || value > (1n << 128n) - 1n)
      throw new Error('value must be a v128 BigInt bit pattern');

    return BigInt.asUintN(128, value);
  }

  // i32 host values may use either signed or unsigned bit-pattern spelling.
  if (type === 1) {
    // Validate before reducing the bits to their signed i32 interpretation.
    if (typeof value !== 'number' || !Number.isInteger(value) || value < -2147483648 || value > 4294967295)
      throw new Error('value must be an i32 integer');

    return BigInt.asIntN(32, BigInt(value));
  }

  // i64 must remain a BigInt throughout host resource construction and mutation.
  if (type === 2) {
    // Reject imprecise Numbers and values outside the supported signed/unsigned i64 patterns.
    if (typeof value !== 'bigint' || value < -(1n << 63n) || value > (1n << 64n) - 1n)
      throw new Error('value must be an i64 BigInt integer');

    return BigInt.asIntN(64, value);
  }

  // Floating-point storage applies f32 rounding here and preserves signed zero in both widths.
  if (typeof value !== 'number') throw new Error('float global value must be a Number');

  const view = new DataView(new ArrayBuffer(8));

  // Encode at the declared width instead of rounding all floating globals through one shared precision.
  if (type === 3) view.setFloat32(0, value, true);
  else view.setFloat64(0, value, true);

  return view.getBigInt64(0, true);
}

/**
 * Decode a numeric global snapshot without changing its retained raw bits, including NaN payloads.
 *
 * @param {bigint} bits
 * @param {number} type
 * @returns {number | bigint}
 */
function hostGlobalValue(bits, type) {
  // Integer and vector kinds retain their width and exact host representation.
  if (type === 1) return Number(BigInt.asIntN(32, bits));

  if (type === 2) return BigInt.asIntN(64, bits);

  if (type === 7) return BigInt.asUintN(128, bits);

  const view = new DataView(new ArrayBuffer(8));

  view.setBigInt64(0, BigInt.asIntN(64, bits), true);

  return type === 3 ? view.getFloat32(0, true) : view.getFloat64(0, true);
}

/**
 * Create an independent global import with decoded access and an exact raw-value API.
 *
 * @param {GlobalOptions} options
 * @param {unknown} [value]
 * @returns {HostGlobal}
 */
export function createGlobal(options, value) {
  hostResourceOptions(options, ['value', 'mutable'], 'global');

  const { value: valueType, mutable = false } = options;
  const { kind: type, descriptor } = hostResourceType(valueType);

  // Mutability participates in import matching and must not be inferred through truthy coercion.
  if (typeof mutable !== 'boolean') throw new Error('global mutable must be a boolean');

  /** @type {ResourceState & {kind: 2}} */
  const state = {
    kind: 2,
    type,
    descriptor,
    mutable: Number(mutable),
    bits: 0n,
    value: null,
    /**
     * Host globals remain valid independently of any guest module load generation.
     *
     * @returns {boolean}
     */
    valid: () => true
  };

  /**
   * Validate a complete replacement before committing either numeric bits or a reference identity.
   *
   * @param {unknown} value
   * @returns {void}
   */
  function assign(value) {
    // Function globals retain a live typed function rather than an untyped callable.
    if (type === 5) hostFunctionReference(value);

    // Reference slots retain their actual host values; only numeric slots are encoded as bits.
    if (type === 5 || type === 6) state.value = value;
    else state.bits = hostGlobalBits(value, type);
  }

  assign(arguments.length > 1 ? value : type === 5 || type === 6 ? null : type === 2 || type === 7 ? 0n : 0);

  /**
   * Read reference values without letting a stale function masquerade as a current guest export.
   *
   * @returns {unknown}
   */
  function currentValue() {
    // Reject a function whose provider was reloaded after it was retained by this host global.
    if (type === 5) hostFunctionReference(state.value);

    return type === 5 || type === 6 ? state.value : hostGlobalValue(state.bits, type);
  }

  const handle = Object.freeze({
    kind: /** @type {const} */ ('global'),
    /**
     * Report the declared value kind used for import matching and raw value slots.
     *
     * @returns {HostValueTypeName}
     */
    get type() {
      return valueType;
    },
    /**
     * Report the descriptor's mutability without exposing the internal import flag.
     *
     * @returns {boolean}
     */
    get mutable() {
      return mutable;
    },
    /**
     * Read the latest value published by a guest or assigned by the host.
     *
     * @returns {unknown}
     */
    get value() {
      return currentValue();
    },
    /**
     * Validate a host write before replacing the current mutable global value.
     *
     * @param {unknown} next     */
    set value(next) {
      // Immutable globals cannot be changed even before they are imported into a guest.
      if (!mutable) throw new Error('immutable global');

      assign(next);
    },
    /**
     * Return raw numeric bits or the retained opaque reference value in the existing typed-slot format.
     *
     * @returns {RawValue}
     */
    getRaw() {
      const width = type === 7 ? 128 : type === 1 || type === 3 ? 32 : 64;

      return type === 5 || type === 6
        ? { type: valueType, value: currentValue() }
        : { type: valueType, bits: BigInt.asUintN(width, state.bits) };
    },
    /**
     * Accept exact raw bits without converting floating-point payloads through JavaScript Numbers.
     *
     * @param {RawValue} slot
     * @returns {void}
     */
    setRaw(slot) {
      // Mutability must be checked before any payload conversion or validation can mutate state.
      if (!mutable) throw new Error('immutable global');

      // Raw assignments must name the global's actual declared value kind.
      if (!slot || slot.type !== valueType) throw new Error('raw global type mismatch');

      // Opaque references use value slots rather than accepting manufactured guest pointer bits.
      if (type === 5 || type === 6) {
        // Distinguish an explicit undefined externref from an omitted raw value field.
        if (!Object.hasOwn(slot, 'value')) throw new Error('raw reference requires an opaque value');

        assign(slot.value);
      } else {
        // Normalize numeric raw bits to the declared width using the same convention as invokeRaw.
        if (typeof slot.bits !== 'bigint') throw new Error('raw global bits must be a BigInt');

        state.bits = BigInt.asUintN(type === 7 ? 128 : type === 1 || type === 3 ? 32 : 64, slot.bits);
      }
    }
  });

  state.handle = handle;

  resourceTypes.set(handle, state);

  return handle;
}

/**
 * Create a host-owned nullable function/external table import with checked element access and growth.
 *
 * @param {TableOptions} [options]
 * @param {unknown} [value]
 * @returns {HostTable}
 */
export function createTable(options = {}, value) {
  hostResourceOptions(options, ['initial', 'maximum', 'address', 'element'], 'table');

  const { initial, maximum, addressType } = hostResourceLimits(options, 16777216, 'table');
  const { element = 'funcref' } = options;
  const { kind: type, descriptor } = hostResourceType(element);

  // Numeric values and instance-owned GC objects are not host table element kinds.
  if (type !== 5 && type !== 6) throw new Error('host table element must be funcref or externref');

  /**
   * Retain live typed function metadata internally while leaving arbitrary externrefs opaque.
   *
   * @param {unknown} value
   * @returns {unknown}
   */
  function entry(value) {
    return type === 5 ? hostFunctionReference(value) : value;
  }

  const fill = entry(arguments.length > 1 ? value : null);
  /** @type {ResourceState & {kind: 3}} */
  const state = {
    kind: 3,
    type,
    descriptor,
    addressType,
    maximum,
    entries: new Array(initial).fill(fill),
    hostOwned: true,
    /**
     * Host tables do not expire when an importing guest reloads.
     *
     * @returns {boolean}
     */
    valid: () => true
  };
  const handle = Object.freeze({
    kind: 'table',
    /**
     * Return the current element count without exposing the mutable entry array.
     *
     * @returns {number}
     */
    get length() {
      return state.entries.length;
    },
    /**
     * Retain the declared address width for import matching and host index checks.
     *
     * @returns {AddressType}
     */
    get address() {
      return addressType === 2 ? 'i64' : 'i32';
    },
    /**
     * Report the nullable abstract reference kind accepted by this table.
     *
     * @returns {TableElement}
     */
    get element() {
      return element;
    },
    /**
     * Distinguish an omitted maximum from a declared table growth limit.
     *
     * @returns {number | undefined}
     */
    get maximum() {
      return maximum === -1 ? undefined : maximum;
    },
    /**
     * Read a checked element while preserving the original provider's callable identity.
     *
     * @param {number | bigint} index
     * @returns {unknown}
     */
    get(index) {
      const slot = hostResourceIndex(index, addressType, state.entries.length - 1, 'table index');
      const stored = /** @type {FunctionReference | null} */ (state.entries[slot]);

      // Externrefs, including undefined and opaque Promises, must be returned without conversion or assimilation.
      if (type === 6 || stored === null) return stored;

      hostFunctionReference(stored.callback);

      return stored.callback;
    },
    /**
     * Validate the slot and replacement before publishing any table mutation.
     *
     * @param {number | bigint} index
     * @param {unknown} value
     * @returns {void}
     */
    set(index, value) {
      const slot = hostResourceIndex(index, addressType, state.entries.length - 1, 'table index');

      state.entries[slot] = entry(value);
    },
    /**
     * Allocate a complete grown entry array before replacing the current table state.
     *
     * @param {number | bigint} delta
     * @param {unknown} [value]
     * @returns {number}
     */
    grow(delta, value) {
      const old = state.entries.length,
        next = old + hostResourceDelta(delta, addressType);
      const fill = entry(arguments.length > 1 ? value : null);

      // Respect declared limits and the table arena's physical entry ceiling before allocation.
      if (next > 16777216 || (maximum !== -1 && next > maximum)) return -1;

      // Validate the fill even for a no-op grow, then retain the existing entry array.
      if (next === old) return old;

      let entries;

      // Allocation failure must not publish a longer or partially filled table.
      try {
        entries = state.entries.concat(new Array(next - old).fill(fill));
      } catch (error) {
        // Report backing allocation exhaustion using the same failed-grow convention as guest tables.
        if (error instanceof RangeError) return -1;

        throw error;
      }

      state.entries = entries;

      return old;
    }
  });

  state.handle = handle;

  resourceTypes.set(handle, state);

  return handle;
}

const asynchronousImports = new WeakSet();
const asynchronousFunctions = new WeakMap();

/**
 * Explicitly distinguish an asynchronous externref import from an opaque Promise value.
 *
 * @param {Function} callback
 * @returns {HostCallback}
 */
export function asyncImport(callback) {
  // Require a callable target before marking an import as asynchronous.
  if (typeof callback !== 'function') throw new Error('async import must be a function');

  /**
   * Forward the call while retaining explicit asynchronous-import metadata.
   *
   * @param {...unknown} args
   * @returns {unknown}
   */
  const binding = (...args) => callback(...args);

  asynchronousImports.add(binding);

  const metadata = functionTypes.get(callback);

  // Preserve typed forwarding information when wrapping an existing guest export.
  if (metadata) functionTypes.set(binding, metadata);

  return binding;
}

// Backing memory and address origins stay private to the host adapters.
/** @type {WeakMap<InterpreterApi, RuntimeBackend>} */
const engineBackends = new WeakMap();

// Validate resource budgets before allocating either a bootstrap or a self-hosted runtime.
const defaultLimits = Object.freeze({
  functions: 65536,
  exports: 512,
  globals: 512,
  callFrames: 512,
  memoryPages: 2048,
  externalReferences: 65535,
  forwardingDepth: 128
});
/** @type {Partial<ResourceLimits>} */
const maximumLimits = Object.freeze({
  functions: 131072,
  exports: 16777216,
  globals: 16777216,
  callFrames: 65535,
  memoryPages: 65536,
  externalReferences: 16777215,
  forwardingDepth: 65535
});
// Additional capacities retain the compact default layout and reserve larger arenas on load.
/** @type {Partial<Record<LimitName, [number, number]>>} */
const arenaLimits = Object.freeze({
  instructions: [131072, 16777216],
  operands: [4096, 65535],
  controls: [4096, 65535],
  syntaxDepth: [256, 65535],
  auxiliarySlots: [131072, 16777216],
  imports: [1024, 65536],
  types: [768, 65536],
  indirectTypes: [1024, 65536],
  referenceTypes: [4096, 131072],
  fields: [32768, 16777216],
  tags: [256, 65536],
  memories: [512, 65536],
  tables: [32, 65536],
  tableEntries: [4096, 16777216],
  dataSegments: [128, 65536],
  elementSegments: [128, 65536],
  elementEntries: [4096, 16777216],
  dataBytes: [65536, 268435456],
  resultShapes: [4096, 16777216],
  gcHeapBytes: [16777216, 268435456],
  gcMapBytes: [4194304, 268435456],
  gcTemporaries: [1024, 65535],
  binaryTextBytes: [1048576, 268435456],
  typeComparisonDepth: [1024, 65535],
  parameters: [128, 65535],
  results: [128, 65535],
  locals: [1088, 65535],
  floatLiteralBytes: [8192, 1048576]
});

/**
 * Validate requested resource budgets and merge them with the default capacities.
 *
 * @param {InterpreterOptions} options
 * @returns {ResourceLimits}
 */
function instanceLimits(options) {
  const requested = options.limits ?? {};

  // Reject malformed capacity options before allocating an interpreter.
  if (typeof requested !== 'object' || requested === null || Array.isArray(requested))
    throw new Error('limits must be an object');

  const limits = /** @type {ResourceLimits} */ ({
    ...defaultLimits,
    ...Object.fromEntries(
      Object.entries(arenaLimits).map(
        /**
         * Retain the default capacity from one bounded arena descriptor.
         *
         * @param {[string, number[]]} entry
         * @returns {[string, number]}
         */
        ([name, [value]]) => [name, /** @type {number} */ (value)]
      )
    )
  });

  // Validate each requested capacity independently before applying any overrides.
  for (const [name, value] of /** @type {[LimitName, number][]} */ (Object.entries(requested))) {
    // Catch misspelled or unsupported capacity names rather than silently ignoring them.
    if (!Object.hasOwn(limits, name)) throw new Error(`unknown limit ${name}`);

    const minimum = arenaLimits[name]?.[0] ?? (['callFrames', 'forwardingDepth'].includes(name) ? 1 : 0);
    const maximum = /** @type {number} */ (arenaLimits[name]?.[1] ?? maximumLimits[name]);

    // Keep each capacity within the physical representation limits of its arena.
    if (!Number.isInteger(value) || value < minimum || value > maximum) {
      throw new Error(`limit ${name} must be an integer from ${minimum} to ${maximum}`);
    }

    limits[name] = value;
  }

  // Ensure every parameter can occupy a local slot in the guest frame.
  if (limits.parameters > limits.locals) throw new Error('limit parameters must not exceed locals');

  return limits;
}

/**
 * Apply validated resource capacities to the interpreter host ABI.
 *
 * @param {InterpreterExports} exports
 * @param {ResourceLimits} limits
 * @returns {void}
 */
function configureLimits(exports, limits) {
  const status = exports.configure_limits(
    limits.functions,
    limits.exports,
    limits.globals,
    limits.callFrames,
    limits.memoryPages
  );

  // Stop construction if the guest ABI rejects the primary resource budgets.
  if (status) throw new Error(`could not configure interpreter limits: status ${status}`);

  // Apply only enlarged arena capacities, retaining the compact default layout otherwise.
  /** @type {LimitName[]} */ (Object.keys(arenaLimits)).forEach(
    /**
     * Configure a larger arena only when its validated capacity differs from the compact default.
     *
     * @param {LimitName} name
     * @param {number} index
     * @returns {void}
     */
    (name, index) => {
      // Reserve larger arenas only when their requested capacities differ from the defaults.
      if (limits[name] !== /** @type {[number, number]} */ (arenaLimits[name])[0]) {
        const status = exports.configure_capacity(index, limits[name]);

        // Stop construction if an enlarged arena cannot be configured.
        if (status) throw new Error(`could not configure ${name}: status ${status}`);
      }
    }
  );
}

/**
 * Create a fresh native interpreter from bootstrap bytes or a caller-owned compiled module.
 * Guest source is never handed to WebAssembly; compiled modules share code, not instance state.
 *
 * @param {BootstrapBinary} binary
 * @param {InterpreterOptions} options
 * @param {RuntimeServices} runtime
 * @returns {Promise<InterpreterApi>}
 */
export async function createBootstrapInterpreter(binary, options, runtime) {
  const limits = instanceLimits(options);
  const instance =
    binary instanceof WebAssembly.Module
      ? new WebAssembly.Instance(binary)
      : (await WebAssembly.instantiate(binary)).instance;

  const exports = /** @type {InterpreterExports} */ (instance.exports);

  configureLimits(exports, limits);

  return wrapInterpreter(exports, { limits, runtime });
}

/**
 * Create the default runtime: one interpreted WAT copy of wiw above the bootstrap.
 *
 * @param {BootstrapBinary} binary
 * @param {InterpreterOptions} options
 * @param {RuntimeServices} runtime
 * @returns {Promise<InterpreterApi>}
 */
export async function createInterpreter(binary, options, runtime) {
  return createInterpretedInterpreter(binary, options, runtime);
}

/**
 * Run a WAT copy of wiw (optimized by default) inside a bootstrap using the same host ABI.
 *
 * @param {BootstrapBinary} binary
 * @param {InterpreterOptions} options
 * @param {RuntimeServices} runtime
 * @returns {Promise<InterpreterApi>}
 */
export async function createInterpretedInterpreter(binary, options, runtime) {
  const limits = instanceLimits(options);
  const parent = await createBootstrapInterpreter(binary, { limits: options.parentLimits }, runtime);
  const backend = /** @type {RuntimeBackend} */ (engineBackends.get(parent));

  // Parent ABI calls are implementation work, not guest-to-guest forwarding.
  backend.countsForwardingDepth = false;

  // Frontends supply the interpreter source before requesting self-hosted execution.
  if (options.source === undefined) throw new Error('self-hosted interpreter source is required');

  parent.load(options.source);
  backend.exports.set_fuel64((1n << 64n) - 1n);
  // The parent holds child arenas as well as the child's full guest-memory capacity.
  backend.exports.enable_interpreter_backing();

  const memoryOffset = backend.memoryOffset + backend.exports.guest_memory_base();
  const exports = /** @type {HostedExports} */ ({ memory: backend.exports.memory });

  // Expose the hosted engine ABI by forwarding its functions through the parent interpreter.
  for (const [name, value] of Object.entries(backend.exports)) {
    // Forward callable exports while retaining the backing memory object directly.
    if (typeof value === 'function')
      exports[name] =
        /**
         * Forward one hosted ABI export through the parent interpreter.
         *
         * @param {...AbiValue} args
         * @returns {unknown}
         */
        (...args) => parent.invoke(name, ...args);
  }

  configureLimits(exports, limits);
  backend.exports.set_fuel64(BigInt(options.parentFuel ?? (1n << 64n) - 1n));

  return wrapInterpreter(exports, {
    runtime,
    memoryOffset,
    limits,

    /**
     * Grow the parent guest memory to hold the interpreted engine backing.
     *
     * @param {number} required
     * @returns {void}
     */
    ensureMemory(required) {
      const current = backend.exports.guest_memory_pages();
      const needed = Math.ceil(required / 65536);

      // Report failure when the parent cannot reserve enough memory for the child engine.
      if (needed > current && parent.growMemory(needed - current) < 0)
        throw new Error('resource limit while growing interpreted backing memory');
    }
  });
}

/**
 * Numeric pointers remain relative to the engine's own memory at every depth.
 *
 * @param {InterpreterExports} exports
 * @param {BackendOptions} options
 * @returns {InterpreterApi}
 */
function wrapInterpreter(exports, { memoryOffset = 0, ensureMemory, limits = instanceLimits({}), runtime }) {
  const { invocationContext, callbackContext } = runtime;

  /**
   * Read the forwarding depth retained by the platform's execution context.
   * @returns {number}
   */
  const currentDepth = () => invocationContext.getStore() ?? 0;

  // Wasm i32 addresses are unsigned even when JavaScript receives a negative Number above 2 GiB.
  const addressExports = Object.fromEntries(
    Object.entries(exports).map(
      /**
       * Normalize pointer-valued ABI exports to unsigned i32 addressing.
       *
       * @param {[string, AbiExport]} entry
       * @returns {[string, AbiExport]}
       */
      ([name, value]) => [
        name,
        typeof value === 'function' &&
        (/(?:_base|_info|_args)$/.test(name) || name === 'error_offset' || name === 'function_signature')
          ? /**
             * Interpret the forwarded pointer result as an unsigned i32 address.
             *
             * @param {...AbiValue} args
             * @returns {number}
             */
            (...args) => /** @type {number} */ (/** @type {AbiForwarder} */ (value)(...args)) >>> 0
          : value
      ]
    )
  );
  const e = /** @type {InterpreterExports} */ (addressExports);
  const backend = { exports: e, memoryOffset, countsForwardingDepth: true };
  let loaded = false;
  /** @type {ResolvedCooperativeOptions | undefined} */
  let cooperative;
  let executionQuantum = 0;
  let invoking = false;
  /** @type {InvocationState | undefined} */
  let activeInvocation;
  let generation = 0;
  /** @type {DiagnosticSource} */
  let diagnosticSource = { format: undefined, length: 0, text: undefined };
  /** @type {(ImportBinding | null)[]} */
  let bindings = [];
  /** @type {ResourceBinding[]} */
  let resources = [];
  let exportedResources = new Map(),
    exportedFunctions = new Map();
  let tableFunctions = new Map();
  let foreignFunctions = new Map();
  /** @type {Map<string, ResourceExport> | undefined} */
  let resourceExports;
  const owner = {};
  const negativeZeroKey = Symbol();
  /** @type {unknown[]} */
  let externalValues = [null];
  /** @type {Map<unknown, number>} */
  let externalIds = new Map();

  /**
   * Ensure that the interpreter backing memory covers the requested byte range.
   *
   * @param {number} required
   * @returns {void}
   */
  function ensure(required) {
    // Delegate backing growth to the parent when this engine is self-hosted.
    if (ensureMemory) return ensureMemory(required);

    // Grow native backing memory only when the requested span exceeds the current allocation.
    if (required > e.memory.buffer.byteLength)
      e.memory.grow(Math.ceil((required - e.memory.buffer.byteLength) / 65536));
  }

  /**
   * Encode text or copy bytes into checked interpreter scratch memory.
   *
   * @param {GuestSource} text
   * @param {number} at
   * @returns {number}
   */
  function write(text, at) {
    const bytes = text instanceof Uint8Array ? text : new TextEncoder().encode(text);
    const required = at + bytes.length;

    ensure(required);
    new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);

    return bytes.length;
  }

  /**
   * Retain source context, deferring UTF-8 coordinate calculation until an error occurs.
   *
   * @param {GuestSource} source
   * @param {boolean} binary
   * @param {number} length
   * @returns {void}
   */
  function rememberSource(source, binary, length) {
    diagnosticSource = {
      format: binary ? 'wasm' : 'wat',
      length,
      text: binary ? undefined : typeof source === 'string' ? source : new TextDecoder().decode(source)
    };
  }

  /**
   * Distinguish original source offsets from the binary decoder's generated WAT coordinates.
   *
   * @param {number} byteOffset
   * @returns {DiagnosticLocation | undefined}
   */
  function diagnosticLocation(byteOffset) {
    const { format, length, text } = diagnosticSource;

    // Expansion begins sixteen bytes past the binary input; runtime tokens belong to that generated text.
    if (format === 'wasm') {
      return byteOffset >= length + 16
        ? { format: 'generated-wat', byteOffset: byteOffset - length - 16 }
        : { format: 'wasm', byteOffset };
    }

    // Coordinates outside original WAT have no meaningful line or column.
    if (format !== 'wat' || byteOffset > length) return undefined;

    const prefix = new TextDecoder().decode(new TextEncoder().encode(text).subarray(0, byteOffset));
    const lines = prefix.split(/\r\n|\r|\n/);

    return { format: 'wat', byteOffset, line: lines.length, column: [...(lines.at(-1) ?? '')].length + 1 };
  }

  /**
   * Snapshot runtime status and retain the established human-readable message for compatibility.
   *
   * @param {number} status
   * @param {DiagnosticPhase} [phase]
   * @param {string} [message]
   * @param {ErrorOptions} [options]
   * @param {ImportIdentity} [imported]
   * @returns {WiwError}
   */
  function statusError(status, phase = activeInvocation?.phase ?? 'access', message, options, imported) {
    const byteOffset = Math.max(0, e.error_offset() - 4096);

    return new WiwError(
      message ?? `${messages[status] ?? 'interpreter error'} at byte ${byteOffset}`,
      {
        code: errorCodes[status] ?? 'INTERPRETER',
        status,
        phase,
        sourceFormat: diagnosticSource.format,
        byteOffset,
        location: diagnosticLocation(byteOffset),
        import: imported
      },
      options
    );
  }

  /**
   * Report binding failures without inventing an instruction location from stale runtime state.
   *
   * @param {string} message
   * @param {string} module
   * @param {string} name
   * @param {string} code
   * @returns {WiwError}
   */
  function importError(message, module, name, code) {
    return new WiwError(message, {
      code,
      phase: 'link',
      sourceFormat: diagnosticSource.format,
      import: { module, name }
    });
  }

  /**
   * Translate a nonzero status while preserving identity-bearing tagged guest exceptions.
   *
   * @param {number} code
   * @param {DiagnosticPhase} [phase]
   * @returns {void}
   */
  function check(code, phase) {
    // Guest exceptions must retain their original tag and payload APIs.
    if (code === 34) throw guestException();

    // Capture metadata before cleanup or subsequent execution changes the runtime status.
    if (code) throw statusError(code, phase);
  }

  /** @type {Map<bigint, WeakRef<WiwException>>} */
  const importedExceptions = new Map();

  /**
   * Reconstruct a guest exception from its exported tag and payload slots.
   *
   * @returns {WiwException}
   */
  function guestException() {
    const reference = e.exception_reference();
    const previous = importedExceptions.get(reference)?.deref();

    // Reuse a live exception wrapper so repeated propagation preserves host identity.
    if (previous) return previous;

    const view = new DataView(e.memory.buffer, memoryOffset),
      at = e.exception_info(reference);
    const tag = view.getInt32(at + 8, true),
      identity = Number(view.getBigUint64(at + 16, true));
    const heap = view.getInt32(e.tag_info(tag) + 24, true),
      count = view.getInt32(at + 4, true) - 1;
    const params = Array.from(
      { length: count },
      /**
       * Read the payload kind at one exception signature slot.
       *
       * @param {undefined} _
       * @param {number} slot
       * @returns {number}
       */
      (_, slot) => e.value_kind(e.heap_param_type(heap, slot))
    );
    // Recover each exception payload slot, including the upper vector half.
    const args = params.map(
      /**
       * Reconstruct one raw exception argument including both vector halves.
       *
       * @param {number} type
       * @param {number} slot
       * @returns {RawValue}
       */
      (type, slot) => {
        const low = view.getBigInt64(at + 32 + slot * 16, true),
          high = view.getBigUint64(at + 40 + slot * 16, true);

        return rawResult(type === 7 ? BigInt.asUintN(64, low) | (high << 64n) : low, type);
      }
    );

    return exceptionSnapshot(identity, params, args);
  }

  /**
   * Copy typed and raw payloads so mutation of caller descriptors cannot change a later rethrow.
   *
   * @param {number} identity
   * @param {number[]} params
   * @param {RawValue[]} args
   * @returns {WiwException}
   */
  function exceptionSnapshot(identity, params, args) {
    const exception = new WiwException();
    const snapshots = args.map(
      /**
       * Copy and freeze one exception payload descriptor.
       *
       * @param {RawValue} arg
       * @returns {Readonly<RawValue>}
       */
      (arg) => Object.freeze({ ...arg })
    );
    const values = snapshots.map(
      /**
       * Decode one retained exception payload without changing reference identity.
       *
       * @param {RawValue} arg
       * @param {number} index
       * @returns {unknown}
       */
      (arg, index) =>
        isHostReference(/** @type {number} */ (params[index]))
          ? arg.value
          : decodedValue(/** @type {bigint} */ (arg.bits), /** @type {number} */ (params[index]))
    );

    exceptionTypes.set(exception, {
      identity,
      params: Object.freeze([...params]),
      args: Object.freeze(snapshots),
      values: Object.freeze(values)
    });

    return exception;
  }

  /**
   * Translate a host exception into the guest exception ABI.
   *
   * @param {WiwException} exception
   * @returns {bigint}
   */
  function importException(exception) {
    const { identity, params, args } = /** @type {ExceptionPayload} */ (exceptionTypes.get(exception));
    // Intern all references before obtaining scratch that foreign-function growth can relocate.
    const bits = args.map(
      /**
       * Encode one exception payload in its declared guest kind.
       *
       * @param {RawValue} arg
       * @param {number} slot
       * @returns {bigint}
       */
      (arg, slot) => rawSlot(arg, /** @type {number} */ (params[slot]))
    );
    const at = e.host_base(),
      maskAt = at + args.length * 8;
    const words = Math.ceil(args.length / 64);

    ensure(maskAt + Math.max(1, words) * 8);

    const view = new DataView(e.memory.buffer, memoryOffset);
    const high = e.argument_high_base();

    // Write each encoded exception payload slot into the guest import-exception ABI.
    bits.forEach(
      /**
       * Write one encoded exception argument into the low/high ABI slots.
       *
       * @param {bigint} value
       * @param {number} slot
       * @returns {void}
       */
      (value, slot) => {
        view.setBigInt64(at + slot * 8, BigInt.asIntN(64, value), true);
        view.setBigInt64(high + slot * 8, BigInt.asIntN(64, value >> 64n), true);
      }
    );

    const mask = params.reduce(
      /**
       * Accumulate the reference root bitmap for exception payload slots.
       *
       * @param {bigint} bits
       * @param {number} type
       * @param {number} slot
       * @returns {bigint}
       */
      (bits, type, slot) => (isHostReference(type) ? bits | (1n << BigInt(slot)) : bits),
      0n
    );

    // Publish every exception root-bitmap word, including parameters beyond the first 64 slots.
    for (let word = 0; word < words; word++)
      view.setBigUint64(maskAt + word * 8, BigInt.asUintN(64, mask >> BigInt(word * 64)), true);

    const reference = e.import_exception_bits(identity, args.length, at, maskAt);

    check(e.error_code());
    e.gc_pin(reference, 1);
    importedExceptions.set(reference, new WeakRef(exception));

    return reference;
  }

  /**
   * Reject operations before the guest module has been initialized.
   *
   * @returns {void}
   */
  function requireLoaded() {
    // Prevent ABI calls from observing an uninitialized guest module.
    if (!loaded) throw new Error('no loaded module');
  }

  /**
   * Require a signed or unsigned i32 representation without silently truncating the value.
   *
   * @param {number} value
   * @returns {void}
   */
  function i32(value) {
    // Accept either signed or unsigned i32 spelling while rejecting truncation or fractional values.
    if (typeof value !== 'number' || !Number.isInteger(value) || value < -2147483648 || value > 4294967295) {
      throw new Error('value must be an i32 integer');
    }
  }

  /**
   * Resolve numeric or exported-name resource selectors before querying canonical records.
   *
   * @param {ResourceSelector} selector
   * @param {number} kind
   * @param {number} count
   * @param {string} label
   * @returns {number}
   */
  function resourceIndex(selector, kind, count, label) {
    // Resolve named selectors through the guest export namespace.
    if (typeof selector === 'string') {
      // Build the export lookup once for the current load generation.
      if (!resourceExports) {
        resourceExports = new Map();

        // Retain each exported resource name, kind and index for subsequent lookups.
        for (let index = 0; index < e.exports_count(); index++) {
          const at = e.export_info(index),
            view = new DataView(e.memory.buffer, memoryOffset);
          const name = readText(view.getUint32(at, true), view.getUint32(at + 4, true));

          resourceExports.set(name, {
            index: view.getInt32(at + 8, true),
            kind: view.getInt32(at + 20, true)
          });
        }
      }

      const descriptor = resourceExports.get(selector);

      // Report a missing export before accessing its resource descriptor.
      if (!descriptor) throw new Error(`unknown export ${selector}`);

      // Prevent using an export of another resource kind as the requested memory, table or tag.
      if (descriptor.kind !== kind) throw new Error(`export kind mismatch ${selector}`);

      return descriptor.index;
    }

    // Distinguish an absent default resource from an out-of-range selector.
    if (!count && selector === 0) throw new Error(`no guest ${label}`);

    // Check numeric selectors against the current resource count.
    if (typeof selector !== 'number' || !Number.isInteger(selector) || selector < 0 || selector >= count)
      throw new Error(`invalid ${label} index`);

    return selector;
  }

  /**
   * Resolve a guest memory selector to its checked resource index.
   *
   * @param {ResourceSelector} [memory]
   * @returns {number}
   */
  function memoryIndex(memory = 0) {
    requireLoaded();

    return resourceIndex(memory, 1, e.guest_memory_present(), 'memory');
  }

  /**
   * Resolve a guest table selector to its checked resource index.
   *
   * @param {ResourceSelector} [table]
   * @returns {number}
   */
  function tableIndex(table = 0) {
    requireLoaded();

    return resourceIndex(table, 3, e.table_count(), 'table');
  }

  /**
   * A supplied tag handle must have a live alias in this loaded module.
   *
   * @param {ResourceSelector} [tag]
   * @returns {number}
   */
  function tagIndex(tag = 0) {
    requireLoaded();

    // Resolve host tag handles by identity rather than by a guest-local numeric index.
    if (typeof tag === 'object' && tag !== null) {
      const state = resourceTypes.get(tag);

      // Reject objects that were not created as wiw tag handles.
      if (!state || state.kind !== 4) throw new Error('value must be a wiw tag');

      // Reject tag handles whose provider has been reloaded.
      if (!state.valid()) throw new Error('stale tag binding');

      // Find the guest tag bound to the host handle's stable identity.
      for (let index = 0; index < e.tag_count(); index++) {
        // Return the matching guest-local tag index without conflating equal signatures.
        if (
          new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true) ===
          state.identity
        )
          return index;
      }

      throw new Error('tag does not belong to loaded module');
    }

    return resourceIndex(tag, 4, e.tag_count(), 'tag');
  }

  /**
   * Read the parameter types declared by a guest exception tag.
   *
   * @param {number} index
   * @returns {number[]}
   */
  function tagParameters(index) {
    const heap = new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 24, true);

    return Array.from(
      { length: e.heap_params(heap) },
      /**
       * Read one parameter kind from the selected tag signature.
       *
       * @param {undefined} _
       * @param {number} slot
       * @returns {number}
       */
      (_, slot) => e.value_kind(e.heap_param_type(heap, slot))
    );
  }

  /**
   * Host-created exceptions are snapshots; guest allocation occurs only when a callback throws one.
   *
   * @param {ResourceSelector} tag
   * @param {unknown[]} args
   * @param {boolean} raw
   * @returns {WiwException}
   */
  function createException(tag, args, raw) {
    synchronizeIn();

    const index = tagIndex(tag),
      params = tagParameters(index);

    // Require exactly the payload arity declared by the selected tag.
    if (args.length !== params.length) throw new Error('exception argument mismatch');

    // Validate and retain each exception argument in both raw and decoded forms.
    const payload = args.map(
      /**
       * Validate and snapshot one decoded or raw host exception argument.
       *
       * @param {unknown} arg
       * @param {number} slot
       * @returns {RawValue}
       */
      (arg, slot) => {
        const bits = raw
          ? rawSlot(arg, /** @type {number} */ (params[slot]))
          : typedValue(arg, /** @type {number} */ (params[slot]));

        // Ask the guest type checker to validate reference-valued exception payloads.
        if (isHostReference(/** @type {number} */ (params[slot]))) {
          const accepts = e.tag_accepts(index, slot, bits);

          check(e.error_code());

          // Reject a payload reference that does not satisfy the tag's declared type.
          if (!accepts) throw new Error('exception payload type mismatch');
        }

        return rawResult(bits, /** @type {number} */ (params[slot]));
      }
    );
    const identity = new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true);

    return exceptionSnapshot(identity, params, payload);
  }

  /**
   * Table64 indices are checked in full before using the bounded physical entry arena.
   *
   * @param {number | bigint} index
   * @param {number} table
   * @returns {number}
   */
  function tableEntry(index, table) {
    // Preserve large table64 indices until their logical bounds have been checked.
    if (typeof index === 'bigint') {
      // Prevent BigInt indices from being accepted for a table32 resource.
      if (e.table_address_type(table) !== 2) throw new Error('BigInt indices require table64');

      // Reject negative or oversized table64 indices before narrowing them to the physical slot.
      if (index < 0n || index >= BigInt(e.table_size(table))) throw new Error('table out of bounds');

      return Number(index);
    }

    // Reject unsafe, fractional or out-of-range Number indices before reading the table.
    if (!Number.isSafeInteger(index) || index < 0 || index >= e.table_size(table))
      throw new Error('table out of bounds');

    return index;
  }

  /**
   * Preserve nullable and concrete reference types instead of checking only funcref/externref kinds.
   *
   * @param {unknown} value
   * @param {number} table
   * @returns {bigint}
   */
  function tableValue(value, table) {
    const type = e.table_type(table);
    const bits = typedValue(value, type);
    const accepts = e.table_accepts(table, bits);

    check(e.error_code());

    // Prevent incompatible references from entering a typed guest table.
    if (!accepts) throw new Error('table element type mismatch');

    return bits;
  }

  /**
   * Normalize only checked physical offsets, retaining full-width memory64 bounds checks.
   *
   * @param {number | bigint} offset
   * @param {number} length
   * @param {number} index
   * @returns {number}
   */
  function memoryRange(offset, length, index) {
    const size = e.memory_pages(index) * 65536;

    // Check memory64 offsets as BigInts before narrowing a physically bounded address.
    if (typeof offset === 'bigint') {
      // Prevent BigInt offsets from being accepted for memory32 resources.
      if (e.memory_width(index) !== 2) throw new Error('BigInt offsets require memory64');

      // Reject negative or out-of-range memory64 offsets before Number conversion.
      if (offset < 0n || offset > BigInt(size)) throw new Error('memory out of bounds');

      offset = Number(offset);
    }

    // Check the complete byte span without allowing unsafe arithmetic or endpoint overflow.
    if (
      !Number.isSafeInteger(offset) ||
      !Number.isSafeInteger(length) ||
      offset < 0 ||
      length < 0 ||
      offset > size ||
      length > size - offset
    )
      throw new Error('memory out of bounds');

    return e.memory_base(index) + offset;
  }

  /**
   * Reject mutation while an invocation is active or suspended.
   *
   * @returns {void}
   */
  function requireIdle() {
    // Protect load and collection state from mutation during an active invocation.
    if (invoking) throw new Error('interpreter is already invoking');
  }

  /**
   * Authorize nested invocation only from the active callback scope.
   *
   * @param {boolean} asynchronous
   * @returns {CallbackScope | undefined}
   */
  function reentryOwner(asynchronous) {
    // Ordinary top-level calls need no suspended callback scope to authorize entry.
    if (!invoking) return;

    // Search active callback ancestors so forwarding cycles can reenter their own suspended instance.
    for (let scope = callbackContext.getStore(); scope; scope = scope.parent) {
      // Accept only the scope that owns this instance's current invocation.
      if (scope.backend === backend && scope.invocation === activeInvocation && scope.active) {
        // Prevent asynchronous reentry from escaping a synchronous outer invocation.
        if (asynchronous && !scope.asynchronous)
          throw new Error('async reentry requires an asynchronous outer invocation');

        return scope;
      }
    }

    throw new Error('interpreter is already invoking');
  }

  /**
   * Require an unsigned 32-bit integer without wrapping the input.
   *
   * @param {number} value
   * @returns {void}
   */
  function u32(value) {
    // Require an exact unsigned i32 value rather than silently wrapping host input.
    if (!Number.isInteger(value) || value < 0 || value > 4294967295) {
      throw new Error('value must be an unsigned i32 integer');
    }
  }

  /**
   * Decode a checked UTF-8 byte span from interpreter backing memory.
   *
   * @param {number} p
   * @param {number} n
   * @returns {string}
   */
  function readText(p, n) {
    return new TextDecoder('utf-8', { ignoreBOM: true }).decode(
      new Uint8Array(e.memory.buffer, memoryOffset + p, n)
    );
  }
  /** @type {ScalarNames} */
  const scalarNames = /** @type {ScalarNames} */ (
    /** @type {unknown} */ ([
      null,
      'i32',
      'i64',
      'f32',
      'f64',
      'funcref',
      'externref',
      'v128',
      'anyref',
      'exnref'
    ])
  );
  let opaqueReferences = new Map();
  /** @type {WeakMap<WeakKey, OpaqueReference>} */
  const opaqueReferenceValues = new WeakMap();

  /**
   * Weak caches preserve identity while callers retain a handle, without retaining dead guest objects forever.
   *
   * @returns {void}
   */
  function refreshHostRoots() {
    // Avoid publishing GC roots when no host-held object or exception wrappers exist.
    if (!opaqueReferences.size && !importedExceptions.size) return;

    const alive = new Set(),
      expired = new Set();

    // Retain live opaque wrappers and gather expired handles for unpinning.
    for (const [key, weak] of opaqueReferences) {
      const value = weak.deref();

      // Pin objects whose host wrappers are still reachable.
      if (value)
        alive.add(
          /** @type {OpaqueReference} */ (opaqueReferenceValues.get(/** @type {WeakKey} */ (value))).bits
        );
      else {
        // Remove expired opaque wrappers and consider their guest objects for unpinning.
        opaqueReferences.delete(key);
        expired.add(BigInt(key.slice(key.indexOf(':') + 1)));
      }
    }

    // Retain live exception wrappers and remove expired entries from the weak cache.
    for (const [bits, weak] of importedExceptions) {
      // Keep exception payload objects rooted while their host exception remains reachable.
      if (weak.deref()) alive.add(bits);
      else {
        // Remove expired exception wrappers and consider their retained payload roots for unpinning.
        importedExceptions.delete(bits);
        expired.add(bits);
      }
    }

    // Remove guest pins only after all live wrappers have been considered.
    // Preserve a pin when another live wrapper still refers to the same guest object.
    for (const bits of expired) if (!alive.has(bits)) e.gc_pin(bits, 0);
  }

  /**
   * Recognize value kinds that require host reference translation.
   *
   * @param {number} type
   * @returns {boolean}
   */
  const isHostReference = (type) => type >= 5 && type !== 7;

  /**
   * Decode a guest value slot, including references and raw vector halves.
   *
   * @param {bigint} bits
   * @param {number} type
   * @returns {unknown}
   */
  function decodedValue(bits, type) {
    // Represent void guest results as undefined.
    if (!type) return undefined;

    // Decode the i32 bit pattern using its signed host representation.
    if (type === 1) return Number(BigInt.asIntN(32, bits));

    // Preserve the full signed i64 value as a BigInt.
    if (type === 2) return BigInt.asIntN(64, bits);

    // Preserve all 128 vector bits without interpreting their lane layout.
    if (type === 7) return BigInt.asUintN(128, bits);

    // Recover function identity through the typed forwarding cache, including null references.
    if (type === 5) return bits === 0n ? null : functionReference(Number(bits - 1n)).callback;

    // Unwrap ordinary externrefs while delegating encoded guest-object references to the opaque path.
    if (type === 6) return bits & 0xc0000000n ? decodedValue(bits, 8) : externalValues[Number(bits)];

    // Decode managed references through generation-bound host wrappers.
    if (type >= 8) {
      // Preserve the guest null-reference value at the host boundary.
      if (bits === 0n) return null;

      // Recover an external value that was wrapped as a guest anyref.
      if (type === 8 && (bits & 0xe0000000n) === 0x20000000n)
        return externalValues[Number(bits & 0x1fffffffn)];

      const key = `${type}:${bits}`;
      let reference = opaqueReferences.get(key)?.deref();

      // Create and pin a wrapper only when this guest object has no live cached host handle.
      if (!reference) {
        reference = Object.freeze({});

        opaqueReferences.set(key, new WeakRef(reference));
        opaqueReferenceValues.set(reference, { bits, type, generation });
        e.gc_pin(bits, 1);
      }

      return reference;
    }

    const view = new DataView(new ArrayBuffer(8));

    view.setBigInt64(0, bits, true);

    return type === 3 ? view.getFloat32(0, true) : view.getFloat64(0, true);
  }

  /**
   * Validate and encode a host value for a declared guest value kind.
   *
   * @param {unknown} value
   * @param {number} type
   * @returns {bigint}
   */
  function typedValue(value, type) {
    // Encode vectors as raw 128-bit patterns rather than scalar numeric values.
    if (type === 7) {
      // Reject vector values that cannot be represented without losing bits.
      if (typeof value !== 'bigint' || value < -(1n << 127n) || value > (1n << 128n) - 1n)
        throw new Error('value must be a v128 BigInt bit pattern');

      return BigInt.asUintN(128, value);
    }

    // Validate i32 values before translating them into the guest's 64-bit host slot.
    if (type === 1) {
      i32(/** @type {number} */ (value));

      return BigInt(/** @type {number | bigint} */ (value));
    }

    // Encode function references through their provider's typed forwarding metadata.
    if (type === 5) {
      // Encode a null function reference as the guest null slot.
      if (value === null) return 0n;

      const metadata = typeof value === 'function' ? functionTypes.get(value) : undefined;

      // Reject stale or untyped functions before interning a guest forwarding binding.
      if (!metadata?.reference || !metadata.valid())
        throw new Error('value must be a live wiw function reference or null');

      return BigInt(tableFunctionIndex(/** @type {FunctionReference} */ (metadata.reference())) + 1);
    }

    // Intern ordinary host values as external references while preserving their identity.
    if (type === 6) {
      // Encode a null external reference without allocating a host reference ID.
      if (value === null) return 0n;

      const opaque = opaqueReferenceValues.get(/** @type {WeakKey} */ (value));

      // Retain the original guest object when an anyref wrapper is passed through an externref slot.
      if (opaque?.type === 8) {
        // Prevent guest-object handles from surviving a reload into a different heap.
        if (opaque.generation !== generation) throw new Error('stale opaque wiw reference');

        return opaque.bits;
      }

      const key = Object.is(value, -0) ? negativeZeroKey : value;

      // Allocate one external reference ID per distinct host value.
      if (!externalIds.has(key)) {
        // Respect the configured external-reference capacity before allocating a new ID.
        if (externalValues.length > limits.externalReferences)
          throw new Error('external reference resource limit');

        externalIds.set(key, externalValues.length);
        externalValues.push(value);
      }

      return BigInt(/** @type {number} */ (externalIds.get(key)));
    }

    // Encode managed guest references while retaining their generation and heap ownership.
    if (type >= 8) {
      // Encode null managed references without requiring an opaque wrapper.
      if (value === null) return 0n;

      const reference = opaqueReferenceValues.get(/** @type {WeakKey} */ (value));

      // Wrap ordinary host values as external anyrefs when no guest object handle exists.
      if (!reference && type === 8) return typedValue(value, 6) | 0x20000000n;

      // Reject references from another generation or with an incompatible managed kind.
      if (!reference || reference.type !== type || reference.generation !== generation)
        throw new Error('value must be a live opaque wiw reference or null');

      return reference.bits;
    }

    // Encode floating-point arguments through a DataView to preserve their guest-width rounding.
    if (type === 3 || type === 4) {
      // Reject implicit coercion of nonnumeric host values into guest floats.
      if (typeof value !== 'number')
        throw new Error(`value must be an ${/** @type {ValueTypeName} */ (scalarNames[type])} Number`);

      const view = new DataView(new ArrayBuffer(8));

      // Round f32 arguments at their declared width rather than first retaining an f64 encoding.
      if (type === 3) view.setFloat32(0, value, true);
      else view.setFloat64(0, value, true);

      return view.getBigInt64(0, true);
    }

    // Require an exact i64 BigInt bit pattern before writing the guest slot.
    if (typeof value !== 'bigint' || value < -(1n << 63n) || value > (1n << 64n) - 1n) {
      throw new Error('value must be an i64 BigInt integer');
    }

    return value;
  }

  /**
   * Resolve an exported function and read its parameter and result kinds.
   *
   * @param {string} name
   * @param {boolean} [includeResults]
   * @returns {IndexedSignature}
   */
  function functionSignature(name, includeResults = true) {
    requireLoaded();

    const at = e.host_base();
    const n = write(name, at);
    const index = e.export_function(at, n);

    check(e.error_code());

    return /** @type {IndexedSignature} */ ({ index, ...signatureAt(index, includeResults) });
  }

  /**
   * Reference descriptors carry opaque values; numeric descriptors retain exact bits.
   *
   * @param {bigint} bits
   * @param {number} type
   * @returns {RawValue}
   */
  function rawResult(bits, type) {
    return isHostReference(type)
      ? {
          type: /** @type {ValueTypeName | null} */ (scalarNames[type]),
          value: decodedValue(bits, type),
          ...(type === 8
            ? {
                heap:
                  bits === 0n
                    ? null
                    : bits & 0x80000000n
                    ? 'i31'
                    : bits & 0x40000000n
                    ? e.reference_category(e.object_type(bits)) === 22
                      ? 'struct'
                      : 'array'
                    : 'any'
              }
            : {})
        }
      : {
          type: /** @type {ValueTypeName | null} */ (scalarNames[type]),
          bits: BigInt.asUintN(type === 7 ? 128 : type === 1 || type === 3 ? 32 : 64, bits)
        };
  }

  /**
   * Validate a raw argument slot and normalize its width without decoding it.
   *
   * @param {unknown} value
   * @param {number} type
   * @returns {bigint}
   */
  function rawSlot(value, type) {
    const arg = /** @type {RawValue} */ (value);

    // Require raw slots to match the declared guest kind.
    if (arg.type !== /** @type {ValueTypeName} */ (scalarNames[type]))
      throw new Error('raw argument type mismatch');

    // Validate raw references through opaque values rather than accepting forged pointer bits.
    if (isHostReference(type)) {
      // Require an actual reference value in a raw reference slot.
      if (!Object.hasOwn(arg, 'value')) throw new Error('raw reference requires an opaque value');

      return typedValue(arg.value, type);
    }

    // Require BigInt bits so raw scalar arguments cannot lose integer precision.
    if (typeof arg.bits !== 'bigint') throw new Error('raw argument type mismatch');

    return type === 7 ? BigInt.asUintN(128, arg.bits) : BigInt.asIntN(64, arg.bits);
  }
  /**
   * Shared state is synchronized at each synchronous guest/host boundary.
   * Type graphs retain nullability and structural heap signatures across independent instances.
   *
   * @param {number} type
   * @param {Map<number, HeapType>} [heaps]
   * @returns {TypeDescription}
   */
  function typeDescription(type, heaps = new Map()) {
    const kind = e.value_kind(type);

    // Numeric value types need no heap graph or nullability metadata.
    if (!isHostReference(kind)) return { kind };

    /** @type {TypeDescription} */
    const result = { kind, nonnull: Boolean(e.type_nonnull(type)), heap: e.reference_category(type) };
    const index = e.type_heap(type);

    // Abstract reference categories have no concrete heap definition to traverse.
    if (index < 0) return result;

    /**
     * Describe a recursive heap type while preserving cycles and group identity.
     *
     * @param {number} index
     * @returns {HeapType}
     */
    const describeHeap = (index) => {
      // Reuse previously described heaps to terminate cycles and preserve recursive group identity.
      const existing = heaps.get(index);
      if (existing) return existing;

      const view = new DataView(e.memory.buffer, memoryOffset);
      const at = e.heap_info(index);
      const heap = /** @type {HeapType} */ ({
        index,
        position: 0,
        parent: null,
        kind: view.getInt32(at, true),
        final: view.getInt32(at + 12, true),
        group: [],
        params: [],
        results: [],
        fields: []
      });

      heaps.set(index, heap);

      const start = view.getInt32(at + 4, true),
        count = view.getInt32(at + 8, true);

      heap.position = index - start;

      const parent = view.getInt32(at + 16, true);

      heap.parent =
        parent < 0 ? null : /** @type {number | HeapType} */ (typeDescription(parent, heaps).heap);

      // Describe function heap members through their parameter and result signatures.
      if (heap.kind === 0) {
        heap.params = Array.from(
          { length: e.heap_params(index) },
          /**
           * Describe one function heap parameter type.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {TypeDescription}
           */
          (_, slot) => typeDescription(e.heap_param_type(index, slot), heaps)
        );
        heap.results = Array.from(
          { length: e.heap_results(index) },
          /**
           * Describe one function heap result type.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {TypeDescription}
           */
          (_, slot) => typeDescription(e.heap_result_type(index, slot), heaps)
        );
      } else {
        // Describe aggregate heap members through their field types and mutability.
        const first = view.getInt32(at + 20, true),
          length = view.getInt32(at + 24, true);

        // Describe every aggregate field with its type and mutability.
        heap.fields = Array.from(
          { length },
          /**
           * Describe one aggregate heap field and its mutability.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {HeapField}
           */
          (_, slot) => {
            const field = e.field_info(first + slot);

            return {
              type: typeDescription(view.getInt32(field, true), heaps),
              mutable: view.getInt32(field + 4, true)
            };
          }
        );
      }

      heap.group = Array.from(
        { length: count },
        /**
         * Describe one member of the retained recursive heap group.
         *
         * @param {undefined} _
         * @param {number} slot
         * @returns {HeapType}
         */
        (_, slot) => describeHeap(start + slot)
      );

      return heap;
    };

    result.heap = describeHeap(index);

    return result;
  }

  /**
   * Recursive group references compare by their relative positions within paired groups.
   *
   * @param {HeapType | number} actual
   * @param {HeapType | number} expected
   * @param {HeapContexts} [contexts]
   * @returns {boolean}
   */
  function equalHeap(actual, expected, contexts = []) {
    // Compare abstract heap categories directly instead of traversing nonexistent concrete definitions.
    if (typeof actual === 'number' || typeof expected === 'number') return actual === expected;

    // Consult paired recursive groups before recursing into their members again.
    for (const [left, right] of contexts) {
      const a = left.indexOf(actual),
        b = right.indexOf(expected);

      // Resolve recursive backreferences by their relative positions within the paired groups.
      if (a >= 0 || b >= 0) return a === b && a >= 0;
    }

    // Reject recursive groups with incompatible sizes or member positions.
    if (actual.position !== expected.position || actual.group.length !== expected.group.length) return false;

    contexts.push([actual.group, expected.group]);

    /**
     * Compare value kind, nullability and heap type within paired recursive groups.
     *
     * @param {TypeDescription} a
     * @param {TypeDescription} b
     * @returns {boolean}
     */
    const sameType = (a, b) =>
      a.kind === b.kind &&
      a.nonnull === b.nonnull &&
      (!isHostReference(a.kind) ||
        equalHeap(
          /** @type {number | HeapType} */ (a.heap),
          /** @type {number | HeapType} */ (b.heap),
          contexts
        ));

    /**
     * Compare each corresponding type in two parameter or result lists.
     *
     * @param {ReadonlyArray<TypeDescription>} a
     * @param {ReadonlyArray<TypeDescription>} b
     * @returns {boolean}
     */
    const sameVector = (a, b) =>
      a.length === b.length &&
      a.every(
        /**
         * Compare the corresponding parameter/result types in paired heap groups.
         *
         * @param {TypeDescription} type
         * @param {number} slot
         * @returns {boolean}
         */
        (type, slot) => sameType(type, /** @type {TypeDescription} */ (b[slot]))
      );
    // Compare corresponding recursive group members, including signatures and aggregate fields.
    const result = actual.group.every(
      /**
       * Compare one recursive group member including its ancestors, signature and fields.
       *
       * @param {HeapType} a
       * @param {number} slot
       * @returns {boolean}
       */
      (a, slot) => {
        const b = /** @type {HeapType} */ (expected.group[slot]);

        return (
          a.kind === b.kind &&
          a.final === b.final &&
          Boolean(a.parent) === Boolean(b.parent) &&
          (!a.parent || equalHeap(a.parent, /** @type {number | HeapType} */ (b.parent), contexts)) &&
          sameVector(a.params, b.params) &&
          sameVector(a.results, b.results) &&
          a.fields.length === b.fields.length &&
          a.fields.every(
            /**
             * Compare one aggregate field type and its mutability.
             *
             * @param {HeapField} field
             * @param {number} i
             * @returns {boolean}
             */
            (field, i) =>
              field.mutable === /** @type {HeapField} */ (b.fields[i]).mutable &&
              sameType(field.type, /** @type {HeapField} */ (b.fields[i]).type)
          )
        );
      }
    );

    contexts.pop();

    return result;
  }

  /**
   * Check whether an imported resource type satisfies the required guest type.
   *
   * @param {TypeDescription} actual
   * @param {TypeDescription} expected
   * @returns {boolean}
   */
  function compatibleType(actual, expected) {
    // Numeric imports require an exact value-kind match.
    if (!isHostReference(expected.kind)) return actual.kind === expected.kind;

    // Reject nonreference inputs and nullable providers for nonnull reference requirements.
    if (!isHostReference(actual.kind) || (expected.nonnull && !actual.nonnull)) return false;

    // Match an abstract heap requirement against the provider's concrete or abstract category.
    if (typeof expected.heap === 'number') {
      const category =
        typeof actual.heap === 'number'
          ? actual.heap
          : /** @type {HeapType} */ (actual.heap).kind === 0
          ? 5
          : /** @type {HeapType} */ (actual.heap).kind === 1
          ? 22
          : 24;

      // Accept an exact abstract category match immediately.
      if (category === expected.heap) return true;

      // Allow the null-only none type wherever a nullable internal heap reference is expected.
      if (category === 26) return [16, 18, 20, 22, 24].includes(expected.heap);

      // Allow the null-only nofunc type to satisfy a nullable function-reference requirement.
      if (category === 28) return expected.heap === 5;

      // Allow the null-only noextern type to satisfy a nullable external-reference requirement.
      if (category === 30) return expected.heap === 6;

      // Allow the null-only noexn type to satisfy a nullable exception-reference requirement.
      if (category === 34) return expected.heap === 32;

      return (
        (expected.heap === 16 && [18, 20, 22, 24].includes(category)) ||
        (expected.heap === 18 && [20, 22, 24].includes(category))
      );
    }

    // A null-only provider can satisfy the corresponding nullable concrete heap requirement.
    if (typeof actual.heap === 'number') {
      const expectedHeap = /** @type {HeapType} */ (expected.heap);

      return actual.heap === (expectedHeap.kind === 0 ? 28 : 26);
    }

    // Walk the provider's declared heap ancestors to find the required structural supertype.
    for (
      let heap = /** @type {number | HeapType | undefined} */ (actual.heap);
      heap && typeof heap !== 'number';
      heap = heap.parent ?? undefined
    )
      // Accept the first structurally equivalent heap in the provider's ancestry.
      if (equalHeap(heap, /** @type {HeapType} */ (expected.heap))) return true;

    return false;
  }

  /**
   * Import the latest memory, global and table state from shared host resource handles.
   *
   * @returns {void}
   */
  function synchronizeIn() {
    // Shared handles become authoritative before copying; a partial refresh cannot authorize any publication.
    for (const binding of resources) binding.publishable = false;

    // Import the latest state of each bound memory, global or table before guest execution.
    for (const binding of resources) {
      const state = binding.state;

      // Tags carry stable identity and require no mutable resource snapshot.
      if (state.kind === 4) continue;

      // Reject resource bindings whose provider has been reloaded.
      if (!state.valid()) throw new Error('stale resource binding');

      // Copy shared host memory contents after bringing the guest's logical size up to date.
      if (state.kind === 1) {
        const delta = state.pages - e.memory_pages(binding.index);

        // Reject imported growth that cannot fit this interpreter's configured memory capacity.
        if (delta > 0 && e.grow_memory(binding.index, delta) < 0)
          throw new Error('shared memory growth exceeds capacity');

        new Uint8Array(e.memory.buffer, memoryOffset + e.memory_base(binding.index), state.bytes.length).set(
          state.bytes
        );
      } else if (state.kind === 2) {
        // Translate shared global values into the guest's scalar or reference representation.
        const bits = isHostReference(state.type) ? typedValue(state.value, state.type) : state.bits;
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.global_info(binding.index);

        view.setBigInt64(at + 24, BigInt.asIntN(64, bits), true);
        view.setBigInt64(at + 72, state.type === 7 ? BigInt.asIntN(64, bits >> 64n) : 0n, true);
      } else {
        // Import the latest shared table size and element references.
        const delta = state.entries.length - e.table_size(binding.index);

        // Reject imported table growth that cannot fit this interpreter's configured table capacity.
        if (delta > 0 && e.grow_guest_table(binding.index, delta) < 0)
          throw new Error('shared table growth exceeds capacity');

        // Import each shared table element after checking reference compatibility.
        state.entries.forEach(
          /**
           * Import one shared table entry after checking its reference compatibility.
           *
           * @param {unknown} entry
           * @param {number} index
           * @returns {void}
           */
          (entry, index) => {
            // Host tables outlive their function providers; reject retained callables after provider reload.
            if (
              state.hostOwned &&
              state.type === 5 &&
              entry &&
              !functionTypes.get(/** @type {FunctionReference} */ (entry).callback)?.valid()
            )
              throw new Error('stale forwarded function');

            const reference = /** @type {FunctionReference | null} */ (entry);
            const target =
              state.type === 5
                ? reference
                  ? tableFunctionIndex(reference)
                  : -1
                : Number(typedValue(entry, state.type)) - 1;

            // Validate managed table references before writing instance-owned object handles.
            if (state.type >= 8) {
              const accepts = e.table_accepts(binding.index, BigInt((target + 1) >>> 0));

              check(e.error_code());

              // Reject foreign managed objects that fail the destination table's type and ownership checks.
              if (!accepts)
                throw new Error(
                  'shared table element type mismatch; managed references belong to their interpreter'
                );
            }

            new DataView(e.memory.buffer, memoryOffset).setInt32(
              e.table_base(binding.index) + index * 4,
              target,
              true
            );
          }
        );
      }
    }

    // Transfer publication authority only after every shared resource has been refreshed successfully.
    for (const binding of resources) binding.publishable = true;
  }

  /**
   * Publish guest memory, global and table changes to shared host resource handles.
   *
   * @returns {void}
   */
  function synchronizeOut() {
    // Publish each bound resource after guest execution or an import boundary.
    for (const binding of resources) {
      const state = binding.state;

      // Failed imports leave the shared handle authoritative; cleanup must not overwrite it with an older guest image.
      if (!binding.publishable || state.kind === 4) continue;

      // Publish the memory's current logical size and complete byte image.
      if (state.kind === 1) {
        state.pages = e.memory_pages(binding.index);
        state.bytes = new Uint8Array(
          e.memory.buffer,
          memoryOffset + e.memory_base(binding.index),
          state.pages * 65536
        ).slice();
      } else if (state.kind === 2) {
        // Publish global bits and decode reference-valued globals for other instances.
        state.bits = new DataView(e.memory.buffer, memoryOffset).getBigInt64(
          e.global_info(binding.index) + 24,
          true
        );

        // Include the upper 64 bits when publishing a vector global.
        if (state.type === 7)
          state.bits =
            BigInt.asUintN(64, state.bits) |
            (BigInt.asUintN(
              64,
              new DataView(e.memory.buffer, memoryOffset).getBigInt64(e.global_info(binding.index) + 72, true)
            ) <<
              64n);

        // Retain host reference identity rather than publishing an instance-local pointer.
        if (isHostReference(state.type)) state.value = decodedValue(state.bits, state.type);
      }
      // Snapshot each guest table element into its shared host representation.
      else
        state.entries = Array.from(
          { length: e.table_size(binding.index) },
          /**
           * Snapshot one guest table entry into its shared host representation.
           *
           * @param {undefined} _
           * @param {number} index
           * @returns {unknown}
           */
          (_, index) => {
            const target = new DataView(e.memory.buffer, memoryOffset).getInt32(
              e.table_base(binding.index) + index * 4,
              true
            );

            return state.type === 5
              ? target < 0
                ? null
                : functionReference(target)
              : decodedValue(BigInt((target + 1) >>> 0), state.type);
          }
        );
    }
  }

  /**
   * Read the result kind or kinds of a guest function.
   *
   * @param {number} index
   * @returns {NumericResults}
   */
  function resultSignature(index) {
    const count = e.function_results(index);

    return count <= 1
      ? e.function_result_type(index, 0)
      : Array.from(
          { length: count },
          /**
           * Read one result kind from the internal function signature.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {number}
           */
          (_, slot) => e.function_result_type(index, slot)
        );
  }

  /**
   * Copy a fresh bulk snapshot before later ABI calls reuse its host scratch bytes.
   *
   * @param {number} index
   * @param {boolean} [includeResults]
   * @returns {NumericSignature}
   */
  function signatureAt(index, includeResults = true) {
    // Direct native calls are cheaper than filling scratch; bulk queries target interpreted forwarding.
    if (!ensureMemory)
      return {
        params: Array.from(
          { length: e.function_params(index) },
          /**
           * Read one parameter kind through the direct native ABI.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {number}
           */
          (_, slot) => e.function_param_type(index, slot)
        ),
        results: includeResults ? resultSignature(index) : undefined
      };

    const at = e.function_signature(index, includeResults ? 1 : 0);

    // Translate a failed bulk signature query before attempting to read its scratch buffer.
    if (!at) check(e.error_code());

    const view = new DataView(e.memory.buffer, memoryOffset);
    const count = view.getUint32(at, true),
      results = view.getUint32(at + 4, true);
    const params = Array.from(
      { length: count },
      /**
       * Copy one parameter kind from the bulk signature snapshot.
       *
       * @param {undefined} _
       * @param {number} slot
       * @returns {number}
       */
      (_, slot) => view.getUint32(at + 8 + slot * 4, true)
    );
    const types = includeResults
      ? Array.from(
          { length: results },
          /**
           * Copy one result kind from the bulk signature snapshot.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {number}
           */
          (_, slot) => view.getUint32(at + 8 + (count + slot) * 4, true)
        )
      : [];

    return { params, results: includeResults ? (results > 1 ? types : types[0] ?? 0) : undefined };
  }

  /**
   * Create or reuse a typed forwarding wrapper for a guest function.
   *
   * @param {number} index
   * @returns {FunctionReference}
   */
  function functionReference(index) {
    // Reuse an existing function wrapper to preserve host reference identity.
    if (tableFunctions.has(index)) return /** @type {FunctionReference} */ (tableFunctions.get(index));

    const descriptor = e.function_info(index),
      view = new DataView(e.memory.buffer, memoryOffset);

    // Recover the provider's reference when this guest function is itself an imported forwarding binding.
    if (view.getInt32(descriptor + 8, true) === -1) {
      const binding = bindings[view.getInt32(descriptor + 12, true)];
      const forwarding = binding && functionTypes.get(binding.callback);

      // Reuse the original provider reference instead of adding another forwarding hop.
      if (forwarding?.reference) {
        const reference = forwarding.reference();

        tableFunctions.set(index, reference);

        return reference;
      }
    }

    const signature = signatureAt(index),
      currentGeneration = generation;

    /**
     * Check that a forwarding handle still belongs to the current loaded generation.
     *
     * @returns {boolean | number}
     */
    const valid = () => e.segments_ready() && generation === currentGeneration;

    /**
     * Forward decoded arguments to the referenced guest function.
     *
     * @param {...unknown} args
     * @returns {unknown}
     */
    const callback = (...args) => {
      reentryOwner(false);

      // Prevent cached callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth before entering another guest call.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      // Validate argument arity before preparing forwarded guest values.
      if (args.length !== signature.params.length) throw new Error('argument mismatch');

      return invokeValues(
        '',
        args.map(
          /**
           * Encode one decoded argument for the forwarded guest function.
           *
           * @param {unknown} value
           * @param {number} slot
           * @returns {bigint}
           */
          (value, slot) => typedValue(value, /** @type {number} */ (signature.params[slot]))
        ),
        false,
        index
      );
    };

    /**
     * Run the operation with raw typed arguments and results.
     *
     * @param {RawValue[]} args
     * @returns {RawResult}
     */
    const raw = (args) => {
      reentryOwner(false);

      // Prevent raw callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth for raw synchronous calls.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      return invokeValues(
        '',
        args.map(
          /**
           * Validate one raw argument for synchronous function forwarding.
           *
           * @param {RawValue} arg
           * @param {number} slot
           * @returns {bigint}
           */
          (arg, slot) => rawSlot(arg, /** @type {number} */ (signature.params[slot]))
        ),
        true,
        index
      );
    };

    /**
     * Forward raw typed arguments while awaiting asynchronous guest imports.
     *
     * @param {RawValue[]} args
     * @returns {Promise<RawResult>}
     */
    const rawAsync = async (args) => {
      reentryOwner(true);

      // Prevent asynchronous raw callbacks from invoking a reloaded guest.
      if (!valid()) throw new Error('stale forwarded function');

      // Bound cross-instance forwarding depth before asynchronous guest forwarding.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      return invokeValues(
        '',
        args.map(
          /**
           * Validate one raw argument for asynchronous function forwarding.
           *
           * @param {RawValue} arg
           * @param {number} slot
           * @returns {bigint}
           */
          (arg, slot) => rawSlot(arg, /** @type {number} */ (signature.params[slot]))
        ),
        true,
        index,
        true
      );
    };

    functionTypes.set(callback, {
      ...signature,
      valid,
      raw,
      rawAsync,
      /**
       * Return the retained provider function reference without allocating a forwarding hop.
       *
       * @returns {FunctionReference}
       */ reference: () => reference
    });

    const reference = { owner, index, callback: exportedFunctions.get(index) ?? callback, signature };

    tableFunctions.set(index, reference);

    return reference;
  }

  /**
   * Resolve a function reference, interning foreign forwarding bindings when needed.
   *
   * @param {FunctionReference} reference
   * @returns {number}
   */
  function tableFunctionIndex(reference) {
    // Reuse local function indices without allocating a foreign forwarding entry.
    if (reference.owner === owner) return reference.index;

    // Reuse an already interned foreign function so table updates retain reference identity.
    if (foreignFunctions.has(reference)) return /** @type {number} */ (foreignFunctions.get(reference));

    const { params, results } = reference.signature;
    const at = e.host_base();

    ensure(at + params.length * 4);
    new Uint32Array(e.memory.buffer, memoryOffset + at, params.length).set(params);

    const slot = bindings.length;
    const index = e.foreign_function(
      params.length,
      /** @type {number} */ (Array.isArray(results) ? results[0] : results),
      at,
      slot
    );

    // Publish all result kinds for foreign functions with multiple results.
    if (index >= 0 && Array.isArray(results)) {
      ensure(at + results.length * 4);
      new Uint32Array(e.memory.buffer, memoryOffset + at, results.length).set(results);
      check(e.foreign_results(index, at, results.length));
    }

    check(e.error_code());
    bindings.push({
      module: '<table>',
      name: String(reference.index),
      params,
      results,
      callback: reference.callback
    });
    foreignFunctions.set(reference, index);
    tableFunctions.set(index, reference);

    return index;
  }

  /**
   * Create or reuse a generation-bound handle for an exported resource.
   *
   * @param {number} index
   * @param {number} kind
   * @returns {ResourceHandle}
   */
  function exportResource(index, kind) {
    const key = `${kind}:${index}`;

    // Preserve identity by returning a cached resource handle for this export.
    if (exportedResources.has(key)) return exportedResources.get(key);

    const imported = resources.find(
      /**
       * Find a binding with the requested guest slot and resource kind.
       *
       * @param {ResourceBinding} binding
       * @returns {boolean}
       */
      (binding) => binding.index === index && binding.state.kind === kind
    );
    let state = imported?.state;

    // Reuse the original host handle when a guest reexports an imported resource.
    if (state?.handle) {
      exportedResources.set(key, state.handle);

      return state.handle;
    }

    // Snapshot a newly exported local resource with a validity guard for this load generation.
    if (!state) {
      const currentGeneration = generation;

      state = /** @type {ResourceState} */ ({
        kind,
        /**
         * Check that the exported resource still belongs to its provider load generation.
         *
         * @returns {boolean}
         */ valid: () => loaded && generation === currentGeneration
      });

      // Retain the tag's stable identity and structural payload signature.
      if (kind === 4)
        Object.assign(state, {
          identity: new DataView(e.memory.buffer, memoryOffset).getInt32(e.tag_info(index) + 16, true),
          descriptor: typeDescription(e.tag_type(index))
        });
      // Retain memory limits, address width and the current byte image for future imports.
      else if (kind === 1)
        Object.assign(state, {
          addressType: e.memory_width(index),
          pages: e.memory_pages(index),
          maximum: e.memory_maximum(index),
          bytes: new Uint8Array(
            e.memory.buffer,
            memoryOffset + e.memory_base(index),
            e.memory_pages(index) * 65536
          ).slice()
        });
      else if (kind === 2) {
        // Retain global mutability, type and current bits for future imports.
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.global_info(index);

        Object.assign(state, {
          type: e.value_kind(view.getInt32(at + 12, true)),
          descriptor: typeDescription(view.getInt32(at + 12, true)),
          mutable: view.getInt32(at + 8, true),
          bits: view.getBigInt64(at + 24, true)
        });

        // The requested global kind fixes the shape populated above.
        const globalState = /** @type {ResourceBase & GlobalState} */ (state);

        // Preserve the upper half of an exported vector global.
        if (globalState.type === 7)
          globalState.bits =
            BigInt.asUintN(64, globalState.bits) |
            (BigInt.asUintN(64, view.getBigInt64(at + 72, true)) << 64n);

        // Retain reference-valued global identity through a host wrapper.
        if (isHostReference(globalState.type))
          globalState.value = decodedValue(globalState.bits, globalState.type);
      } else
        Object.assign(state, {
          addressType: e.table_address_type(index),
          type: e.table_type(index),
          descriptor: typeDescription(
            new DataView(e.memory.buffer, memoryOffset).getInt32(e.table_info(index) + 16, true)
          ),
          maximum: e.table_max(index),
          // Retain the initial table contents as generation-bound host references.
          entries: Array.from(
            { length: e.table_size(index) },
            /**
             * Retain one initial guest table entry in the exported resource snapshot.
             *
             * @param {undefined} _
             * @param {number} slot
             * @returns {unknown}
             */
            (_, slot) => {
              const target = new DataView(e.memory.buffer, memoryOffset).getInt32(
                e.table_base(index) + slot * 4,
                true
              );

              return e.table_type(index) === 5
                ? target < 0
                  ? null
                  : functionReference(target)
                : decodedValue(BigInt((target + 1) >>> 0), e.table_type(index));
            }
          )
        });

      // A newly exported local resource starts with an authoritative guest snapshot.
      resources.push({ index, state, publishable: true });
    }

    const handle = Object.freeze({
      kind: /** @type {ResourceHandle['kind']} */ (['function', 'memory', 'global', 'table', 'tag'][kind])
    });

    resourceTypes.set(handle, state);
    exportedResources.set(key, handle);

    return handle;
  }

  /**
   * Reject an already aborted request before it can execute guest instructions or initialization side effects.
   *
   * @param {boolean} asynchronous
   * @returns {void}
   */
  function preflightCancellation(asynchronous) {
    // Synchronous APIs retain their existing uninterrupted execution contract.
    if (asynchronous && cooperative?.signal?.aborted) {
      throw new WiwError(
        'guest execution aborted',
        {
          code: 'ABORTED',
          phase: 'request'
        },
        { cause: cooperative.signal.reason }
      );
    }
  }

  /**
   * Cancel retained runtime frames at a safe boundary after any callback-owned children have settled.
   *
   * @param {boolean} asynchronous
   * @returns {void}
   */
  function checkCancellation(asynchronous) {
    const signal = asynchronous ? activeInvocation?.cooperative?.signal : undefined;

    // A host callback remains responsible for its own operation until it has finished.
    if (signal?.aborted) {
      e.cancel_execution();

      throw statusError(35, undefined, undefined, { cause: signal.reason });
    }
  }

  /**
   * Select the async quantum for this invocation, leaving synchronous nested calls uninterrupted.
   *
   * @returns {void}
   */
  function configureExecution() {
    const quantum = activeInvocation?.cooperative?.quantum ?? 0;

    // Ordinary calls need no extra ABI round trip when the quantum remains disabled.
    if (quantum !== executionQuantum) {
      e.set_execution_quantum(quantum);

      executionQuantum = quantum;
    }
  }

  /**
   * The synchronous runner never yields; async imports resume this same state machine.
   *
   * @param {bigint} value
   * @param {boolean} [raw]
   * @returns {unknown}
   */
  function drive(value, raw = false) {
    return driveSteps(value, raw, false).next().value;
  }

  /**
   * Run guest execution while awaiting imports and preserving opaque reference values.
   *
   * @param {bigint} value
   * @param {boolean} [raw]
   * @returns {Promise<InvocationResult>}
   */
  async function driveAsync(value, raw = false) {
    const steps = driveSteps(value, raw, true);
    let step = steps.next();

    // Continue driving the guest until its imports and final result have completed.
    while (!step.done) {
      let returned;

      // Await the pending host operation before resuming the generator with its result.
      try {
        returned = await step.value;
      } catch (error) {
        // Feed a rejected host operation back into the guest driver so normal failure handling runs.
        step = steps.throw(error);
        continue;
      }

      step = steps.next(returned);
    }

    return { value: step.value };
  }

  /**
   * Yield pending imports and resume guest execution with translated results or exceptions.
   *
   * @param {bigint} value
   * @param {boolean} raw
   * @param {boolean} asynchronous
   * @yields {PromiseLike<unknown>}
   * @returns {Generator<PromiseLike<unknown>, unknown, unknown>}
   */
  function* driveSteps(value, raw, asynchronous) {
    // Service each pending guest import before resuming instruction execution.
    while (e.pending_import() >= 0 || (activeInvocation?.cooperative && e.execution_paused())) {
      // Dispatch suspensions yield a macrotask so timers, IO and abort listeners can run without a host import.
      if (activeInvocation?.cooperative && e.execution_paused()) {
        synchronizeOut();

        yield runtime.yieldTask();

        synchronizeIn();

        checkCancellation(asynchronous);
        configureExecution();

        value = e.resume_execution();

        check(e.error_code());
        continue;
      }

      checkCancellation(asynchronous);

      const binding = /** @type {ImportBinding} */ (bindings[e.pending_import()]);
      let result = 0n;
      /** @type {unknown} */
      let failure;
      let failed = false;

      // Capture argument conversion and callback failures for translation through the guest import ABI.
      try {
        const view = new DataView(e.memory.buffer, memoryOffset);
        const at = e.pending_args();
        const pendingHigh = e.pending_high_args();
        // Read each pending import argument without losing vector halves or reference identity.
        const rawArgs = binding.params.map(
          /**
           * Copy one pending import argument with exact vector high bits.
           *
           * @param {number} type
           * @param {number} index
           * @returns {RawValue}
           */
          (type, index) => {
            let bits = view.getBigInt64(at + index * 8, true);

            // Combine both argument halves before forwarding a vector import.
            if (type === 7)
              bits =
                BigInt.asUintN(64, bits) |
                (BigInt.asUintN(64, view.getBigInt64(pendingHigh + index * 8, true)) << 64n);

            return rawResult(bits, type);
          }
        );
        const args = rawArgs.map(
          /**
           * Decode one import argument while preserving opaque reference identity.
           *
           * @param {RawValue} value
           * @param {number} index
           * @returns {unknown}
           */
          (value, index) =>
            isHostReference(/** @type {number} */ (binding.params[index]))
              ? value.value
              : decodedValue(
                  /** @type {bigint} */ (value.bits),
                  /** @type {number} */ (binding.params[index])
                )
        );

        synchronizeOut();

        const forwarding = functionTypes.get(binding.callback);
        const forward = asynchronous && forwarding?.rawAsync ? forwarding.rawAsync : forwarding?.raw;
        // Promise externrefs are ordinary values unless the binding explicitly opts into awaiting.
        const awaitable =
          binding.results !== 6 ||
          asynchronousImports.has(binding.callback) ||
          (asynchronous && forwarding?.rawAsync);
        let returned;
        const scope = {
          backend,
          invocation: /** @type {InvocationState} */ (activeInvocation),
          asynchronous,
          active: true,
          children: new Set(),
          parent: callbackContext.getStore()
        };

        // Run the callback inside its reentry scope and deactivate that scope on every exit path.
        try {
          returned = callbackContext.run(
            scope,
            /**
             * Run the forwarding adapter or host callback inside the active ownership scope.
             *
             * @returns {unknown}
             */
            () => (forward ? forward(rawArgs) : binding.callback(...args))
          );

          // Await promises only for imports whose ABI opts into asynchronous completion.
          if (
            asynchronous &&
            awaitable &&
            returned &&
            typeof (/** @type {PromiseLike<unknown>} */ (returned).then) === 'function'
          )
            returned = yield /** @type {PromiseLike<unknown>} */ (returned);
        } finally {
          // Deactivate the callback scope before joining children and importing their resource effects.
          scope.active = false;

          // Even an unawaited nested call must finish before its caller can resume the guest.
          if (asynchronous && scope.children.size) yield Promise.allSettled([...scope.children]);

          // Import side effects remain visible even when a rejected guest exception enters a handler.
          synchronizeIn();
        }

        // Reject asynchronous callback results when the caller selected synchronous invocation.
        if (
          !asynchronous &&
          awaitable &&
          returned &&
          typeof (/** @type {PromiseLike<unknown>} */ (returned).then) === 'function'
        ) {
          // Consume rejected promises while rejecting asynchronous callbacks for this synchronous ABI.
          Promise.resolve(returned).catch(
            /**
             * Consume a rejected Promise while rejecting async callbacks for the synchronous ABI.
             *
             * @returns {void}
             */
            () => {}
          );

          throw new Error('import callbacks must be synchronous');
        }

        const resultCount = Array.isArray(binding.results) ? binding.results.length : binding.results ? 1 : 0;

        // Check result capacity before writing into the guest's shared operand arena.
        if (resultCount && resultCount > e.pending_result_capacity())
          throw new Error('operand stack resource limit');

        // Validate and publish all slots of a multi-value import result.
        if (Array.isArray(binding.results)) {
          const resultTypes = binding.results;

          // Require the returned array to have exactly the import's declared result arity.
          if (!Array.isArray(returned) || returned.length !== binding.results.length)
            throw new Error('import result count mismatch');

          const slots = returned.map(
            /**
             * Encode one result slot returned by the host import.
             *
             * @param {unknown} value
             * @param {number} slot
             * @returns {bigint}
             */
            (value, slot) =>
              forward
                ? rawSlot(value, /** @type {number} */ (resultTypes[slot]))
                : typedValue(value, /** @type {number} */ (resultTypes[slot]))
          );
          const resultAt = e.pending_args();

          ensure(resultAt + slots.length * 8);

          const output = new DataView(e.memory.buffer, memoryOffset);

          // Write each multi-value import result into its low and high guest slots.
          slots.forEach(
            /**
             * Write one host result into its parallel low/high ABI slots.
             *
             * @param {bigint} value
             * @param {number} slot
             * @returns {void}
             */
            (value, slot) => {
              output.setBigInt64(resultAt + slot * 8, BigInt.asIntN(64, value), true);
              output.setBigInt64(
                e.pending_high_args() + slot * 8,
                resultTypes[slot] === 7 ? BigInt.asIntN(64, value >> 64n) : 0n,
                true
              );
            }
          );

          result = /** @type {bigint} */ (slots[0]);
        } else if (binding.results) {
          // Encode the single declared import result; void imports leave the result slot unused.
          result = forward ? rawSlot(returned, binding.results) : typedValue(returned, binding.results);

          // Publish a vector result's upper half in the separate high-slot ABI.
          if (binding.results === 7) {
            new DataView(e.memory.buffer, memoryOffset).setBigInt64(
              e.pending_high_args(),
              BigInt.asIntN(64, result >> 64n),
              true
            );

            result = BigInt.asIntN(64, result);
          }
        }
      } catch (error) {
        // Retain callback failures so guest resumption can trap or enter an exception handler.
        failure = error;
        failed = true;
      }

      checkCancellation(asynchronous);
      configureExecution();

      // Guest exceptions retain their tag identity and unwind through the caller's own handlers.
      if (failed && failure instanceof WiwException && exceptionTypes.has(failure)) {
        value = e.resume_exception(importException(failure));

        check(e.error_code());
        continue;
      }

      // The scalar ABI carries only the low 64 bits; vector high bits live in their separate slots.
      value = e.resume64(BigInt.asIntN(64, result), failed ? 1 : 0);

      // Attach the import name, source offset and original cause to ordinary host failures.
      if (failed) {
        throw statusError(
          20,
          undefined,
          `host import ${binding.module}.${binding.name} failed at byte ${Math.max(
            0,
            e.error_offset() - 4096
          )}`,
          { cause: failure },
          { module: binding.module, name: binding.name }
        );
      }

      check(e.error_code());
    }

    check(e.error_code());

    // The bootstrap avoids scratch metadata work when its native queries cross no interpreted boundary.
    if (!ensureMemory) {
      const count = e.result_count();

      // Decode each slot when the guest export returns multiple values.
      if (count > 1) {
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.result_base();

        // Decode each returned result slot according to its guest kind.
        return Array.from(
          { length: count },
          /**
           * Decode one completed result from the direct native ABI.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {unknown}
           */
          (_, slot) => {
            let bits = view.getBigInt64(at + slot * 8, true);
            const type = e.result_type(slot);

            // Combine both halves before decoding a vector in a multi-value result.
            if (type === 7)
              bits =
                BigInt.asUintN(64, bits) | (view.getBigUint64(e.result_high_base() + slot * 8, true) << 64n);

            return raw ? rawResult(bits, type) : decodedValue(bits, type);
          }
        );
      }

      const type = e.result_type(0);

      // Combine the high half before decoding a single vector result.
      if (type === 7)
        value =
          BigInt.asUintN(64, value) |
          (new DataView(e.memory.buffer, memoryOffset).getBigUint64(e.result_high_base(), true) << 64n);

      return raw ? rawResult(value, type) : decodedValue(value, type);
    }

    const info = e.result_info();

    // Translate a failed bulk result query before reading its scratch descriptor.
    if (!info) check(e.error_code());

    const output = new DataView(e.memory.buffer, memoryOffset);
    const resultCount = output.getUint32(info, true),
      at = output.getUint32(info + 4, true),
      highAt = output.getUint32(info + 8, true);
    // Copy kinds and bits before decoding references can issue further metadata queries.
    const types = Array.from(
      { length: Math.max(1, resultCount) },
      /**
       * Copy one result kind from the hosted signature snapshot.
       *
       * @param {undefined} _
       * @param {number} slot
       * @returns {number}
       */
      (_, slot) => output.getUint32(info + 12 + slot * 4, true)
    );

    // Preserve each typed raw slot when an export has multiple results.
    if (resultCount > 1) {
      // Retain each raw result slot without converting floating-point values.
      const bits = Array.from(
        { length: resultCount },
        /**
         * Reconstruct one completed numeric result including vector high bits.
         *
         * @param {undefined} _
         * @param {number} slot
         * @returns {bigint}
         */
        (_, slot) => {
          const low = output.getBigInt64(at + slot * 8, true);

          return types[slot] === 7
            ? BigInt.asUintN(64, low) | (output.getBigUint64(highAt + slot * 8, true) << 64n)
            : low;
        }
      );

      return bits.map(
        /**
         * Return one raw or decoded result according to the invocation mode.
         *
         * @param {bigint} bits
         * @param {number} slot
         * @returns {unknown}
         */
        (bits, slot) =>
          raw
            ? rawResult(bits, /** @type {number} */ (types[slot]))
            : decodedValue(bits, /** @type {number} */ (types[slot]))
      );
    }

    const resultType = types[0];

    // Restore all 128 bits of a single raw vector result.
    if (resultType === 7) value = BigInt.asUintN(64, value) | (output.getBigUint64(highAt, true) << 64n);

    return raw
      ? rawResult(value, /** @type {number} */ (resultType))
      : decodedValue(value, /** @type {number} */ (resultType));
  }

  /**
   * Invoke raw slots synchronously.
   * @overload
   * @param {string} name
   * @param {bigint[]} values
   * @param {true} raw
   * @param {number | undefined} [index]
   * @param {false} [asynchronous]
   * @returns {RawResult}
   */
  /**
   * Invoke raw slots asynchronously.
   * @overload
   * @param {string} name
   * @param {bigint[]} values
   * @param {true} raw
   * @param {number | undefined} index
   * @param {true} asynchronous
   * @returns {Promise<RawResult>}
   */
  /**
   * Invoke with a mode selected at runtime.
   * @overload
   * @param {string} name
   * @param {bigint[]} values
   * @param {boolean} [raw]
   * @param {number | undefined} [index]
   * @param {boolean} [asynchronous]
   * @returns {unknown}
   */
  /**
   * Run either public scalar values or exact raw slots through the same protected invocation.
   *
   * @param {string} name
   * @param {bigint[]} values
   * @param {boolean} [raw]
   * @param {number | undefined} [index]
   * @param {boolean} [asynchronous]
   * @returns {unknown}
   */
  function invokeValues(name, values, raw = false, index = undefined, asynchronous = false) {
    preflightCancellation(asynchronous);

    const ownerScope = reentryOwner(asynchronous);
    const previousInvocation = activeInvocation;
    const nested = invoking;

    // Save the suspended guest state before entering a callback-owned nested invocation.
    if (nested) check(e.begin_reentry(/** @type {number} */ (index)));

    activeInvocation = { phase: 'invoke', cooperative: asynchronous ? cooperative : undefined };
    invoking = true;

    let at, n;
    /** @type {number} */
    let argumentsAt;

    // Prepare arguments and backing memory while retaining a recovery path for partial failure.
    try {
      synchronizeIn();

      refreshHostRoots();

      at = e.host_base();
      // Indexed calls already resolved their export and need no second name write.
      n = index === undefined ? write(name, at) : 0;
      argumentsAt = Math.ceil((at + n) / 8) * 8;

      ensure(argumentsAt + values.length * 8);

      const view = new DataView(e.memory.buffer, memoryOffset);
      const highAt = values.length ? e.argument_high_base() : 0;

      // Write each prepared argument into the guest invocation buffers.
      values.forEach(
        /**
         * Publish one prepared argument into the guest invocation buffers.
         *
         * @param {bigint} value
         * @param {number} index
         * @returns {void}
         */
        (value, index) => {
          view.setBigInt64(argumentsAt + index * 8, BigInt.asIntN(64, value), true);
          view.setBigInt64(highAt + index * 8, value > 0n ? BigInt.asIntN(64, value >> 64n) : 0n, true);
        }
      );
    } catch (error) {
      // Restore the previous invocation if preparing the nested call fails.
      // Unwind the synthetic reentry boundary created for the failed nested call.
      if (nested) check(e.end_reentry());

      activeInvocation = previousInvocation;
      invoking = !!previousInvocation;

      throw error;
    }

    /**
     * Restore invocation ownership and saved execution state after completion or failure.
     *
     * @returns {void}
     */
    const cleanup = () => {
      // Publish resource changes and abort any remaining suspended import before restoring ownership.
      try {
        // Cancel a still-pending import so the engine cannot remain suspended after cleanup.
        if (activeInvocation?.cooperative && e.execution_paused()) e.cancel_execution();
        else if (e.pending_import() >= 0) e.resume64(0n, 1);

        synchronizeOut();
      } finally {
        // Restore the caller's suspended frames after the nested invocation ends.
        if (nested) check(e.end_reentry());

        activeInvocation = previousInvocation;
        invoking = !!previousInvocation;
      }
    };

    /**
     * Enter the prepared guest function by export name or resolved function index.
     *
     * @returns {bigint}
     */
    const start = () => {
      configureExecution();

      return index === undefined
        ? e.invoke64(at, n, argumentsAt, values.length)
        : e.invoke_index64(index, argumentsAt, values.length);
    };

    // Use the asynchronous driver and retain the callback-owned completion obligation.
    if (asynchronous) {
      const depth = currentDepth() + (backend.countsForwardingDepth ? 1 : 0);
      // Track guest completion separately from public Promise assimilation of an externref result.
      const completion = invocationContext.run(
        depth,
        /**
         * Drive asynchronous guest execution and guarantee invocation cleanup.
         *
         * @returns {Promise<InvocationResult>}
         */
        async () => {
          // Run the awaited guest call while guaranteeing invocation cleanup.
          try {
            return await driveAsync(start(), raw);
          } finally {
            // Restore invocation state whether the asynchronous guest call returns or throws.
            cleanup();
          }
        }
      );

      // Track nested completion so an unawaited child cannot outlive its outer callback.
      if (ownerScope) {
        ownerScope.children.add(completion);
        completion.then(
          /**
           * Release the successful nested call from its callback ownership obligation.
           *
           * @returns {boolean}
           */
          () => ownerScope.children.delete(completion),
          /**
           * Release the failed nested call from its callback ownership obligation.
           *
           * @returns {boolean}
           */
          () => ownerScope.children.delete(completion)
        );
      }

      return completion.then(
        /**
         * Unbox the completed async result at the public Promise boundary.
         *
         * @param {InvocationResult} result
         * @returns {unknown}
         */
        (result) => result.value
      );
    }

    /**
     * Execute the prepared operation within its invocation context.
     *
     * @returns {unknown}
     */
    const run = () => {
      // Guarantee cleanup even when synchronous guest execution traps.
      try {
        return drive(start(), raw);
      } finally {
        // Restore invocation state whether the synchronous guest call returns or traps.
        cleanup();
      }
    };

    return backend.countsForwardingDepth ? invocationContext.run(currentDepth() + 1, run) : run();
  }

  /**
   * Validate decoded host arguments against the export signature before invocation.
   *
   * @param {string} name
   * @param {unknown[]} args
   * @param {boolean} asyncInvocation
   * @returns {unknown}
   */
  function invokePublic(name, args, asyncInvocation) {
    reentryOwner(asyncInvocation);
    requireLoaded();

    // Bound forwarding depth before decoding public invocation arguments.
    if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
      throw new Error('forwarding depth limit');

    // Reject argument lists larger than the configured parameter arena.
    if (args.length > limits.parameters) throw new Error(`too many arguments (maximum ${limits.parameters})`);

    const signature = functionSignature(name, false);

    // Require the export's exact parameter arity before converting arguments.
    if (args.length !== signature.params.length) throw new Error('argument mismatch');

    // Validate each decoded argument and attach a useful type error on failure.
    const values = args.map(
      /**
       * Encode one public invocation argument using the guest signature.
       *
       * @param {unknown} arg
       * @param {number} index
       * @returns {bigint}
       */
      (arg, index) => {
        // Convert each argument using the guest's declared value kind.
        try {
          return typedValue(arg, /** @type {number} */ (signature.params[index]));
        } catch (error) {
          // Preserve reference diagnostics while adding useful scalar argument-type messages.
          // Keep precise reference ownership and liveness errors instead of replacing them with scalar diagnostics.
          if (/** @type {number} */ (signature.params[index]) >= 5) throw error;

          throw new Error(
            /** @type {number} */ (signature.params[index]) === 2
              ? 'arguments must be i64 BigInt integers'
              : /** @type {number} */ (signature.params[index]) === 1
              ? 'arguments must be i32 integers'
              : `arguments must be ${
                  /** @type {ValueTypeName} */ (scalarNames[/** @type {number} */ (signature.params[index])])
                } Numbers`
          );
        }
      }
    );

    return invokeValues('', values, false, signature.index, asyncInvocation);
  }

  /**
   * Validate raw value slots against the export signature before invocation.
   *
   * @param {string} name
   * @param {RawValue[]} args
   * @param {boolean} asyncInvocation
   * @returns {RawResult | Promise<RawResult>}
   */
  function invokeRawPublic(name, args, asyncInvocation) {
    reentryOwner(asyncInvocation);
    requireLoaded();

    // Bound forwarding depth before preparing a raw public invocation.
    if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
      throw new Error('forwarding depth limit');

    const signature = functionSignature(name, false);

    // Require the raw argument count to match the export signature.
    if (args.length !== signature.params.length) throw new Error('argument mismatch');

    // Normalize each raw argument to its declared guest kind.
    const values = args.map(
      /**
       * Validate one raw public invocation argument using the guest signature.
       *
       * @param {RawValue} arg
       * @param {number} index
       * @returns {bigint}
       */
      (arg, index) => {
        return rawSlot(arg, /** @type {number} */ (signature.params[index]));
      }
    );

    return /** @type {RawResult | Promise<RawResult>} */ (
      invokeValues('', values, true, signature.index, asyncInvocation)
    );
  }
  const api = {
    /**
     * Resource adapters bind to this revision and reject reuse after load/validation attempts.
     *
     * @returns {number}
     */
    get generation() {
      return generation;
    },

    /**
     * Parse and validate a module without imports, resource allocation, segment effects or start execution.
     *
     * @param {GuestSource} source
     * @param {boolean} [binarySource]
     * @returns {InterpreterApi}
     */
    validate(source, binarySource = false) {
      requireIdle();

      loaded = false;
      generation++;
      resourceExports = undefined;

      const sourceLength = write(source, 4096);

      rememberSource(source, binarySource, sourceLength);

      e.validation_only(1);

      // Validate source with instantiation disabled and restore the normal load mode afterward.
      try {
        check(binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength), 'validate');
      } finally {
        // Restore normal instantiation behavior after a validation-only attempt.
        e.validation_only(0);
      }

      return api;
    },

    /**
     * Load, bind and initialize a guest module through the selected interpreter.
     *
     * @param {GuestSource} source
     * @param {HostImports} [imports]
     * @param {boolean} [binarySource]
     * @param {boolean} [asynchronous]
     * @returns {void | Promise<void>}
     */
    load(source, imports = {}, binarySource = false, asynchronous = false) {
      requireIdle();
      preflightCancellation(asynchronous);

      loaded = false;
      generation++;
      resourceExports = undefined;
      bindings = [];
      resources = [];

      importedExceptions.clear();

      exportedResources = new Map();
      exportedFunctions = new Map();
      tableFunctions = new Map();
      foreignFunctions = new Map();
      externalValues = [null];
      externalIds = new Map();
      opaqueReferences = new Map();

      const sourceLength = write(source, 4096);

      rememberSource(source, binarySource, sourceLength);

      const status = binarySource ? e.load_binary(4096, sourceLength) : e.load(4096, sourceLength);

      // Modules without resource imports initialize segments inside load; expose that actual failure phase.
      check(status, status && e.load_initializing() ? 'initialize' : 'load');

      // Give each declared guest tag a fresh identity for this module generation.
      for (let index = 0; index < e.tag_count(); index++) e.bind_tag(index, nextTagIdentity++);

      const resolved = [],
        resourceBindings = [];
      let pages = e.memory_minimum(0),
        maximum = e.memory_maximum(0),
        entries = e.table_size(0),
        tableMaximum = e.table_max(0);

      // Resolve and validate every function and resource import before initialization.
      for (let index = 0; index < e.import_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset);
        const at = e.import_info(index);
        const target = view.getInt32(at, true);
        const module = readText(view.getUint32(at + 4, true), view.getUint32(at + 8, true));
        const name = readText(view.getUint32(at + 12, true), view.getUint32(at + 16, true));
        const kind = view.getInt32(at + 24, true);
        const namespace = imports && Object.hasOwn(imports, module) ? imports[module] : undefined;
        const callback = namespace && Object.hasOwn(namespace, name) ? namespace[name] : undefined;

        // Bind resource imports through typed host handles instead of treating them as callbacks.
        if (kind) {
          const state = callback && resourceTypes.get(callback);

          // Report a missing resource handle before reading its signature or state.
          if (!state)
            throw importError(`missing resource import ${module}.${name}`, module, name, 'MISSING_IMPORT');

          // Reject a resource whose provider is stale or whose kind differs from the declared import.
          if (!state.valid() || state.kind !== kind)
            throw importError(
              `import signature mismatch or stale binding ${module}.${name}`,
              module,
              name,
              'IMPORT_TYPE_MISMATCH'
            );

          // Require tag payload signatures to agree in both directions before sharing identity.
          if (state.kind === 4) {
            const descriptor = typeDescription(e.tag_type(target));

            // Reject tag imports whose structural payload signatures differ.
            if (
              !compatibleType(state.descriptor, descriptor) ||
              !compatibleType(descriptor, state.descriptor)
            )
              throw importError(
                `import signature mismatch ${module}.${name}`,
                module,
                name,
                'IMPORT_TYPE_MISMATCH'
              );

            e.bind_tag(target, state.identity);
            resourceBindings.push({ index: target, state, publishable: false });
            resolved.push(null);
            continue;
          }

          // Check imported memory and table limits and address widths before binding their storage.
          if (state.kind === 1 || state.kind === 3) {
            // Prevent memory32/table32 resources from satisfying memory64/table64 imports or vice versa.
            if (
              state.addressType !== (state.kind === 1 ? e.memory_width(target) : e.table_address_type(target))
            )
              throw importError(
                `import signature mismatch ${module}.${name}`,
                module,
                name,
                'IMPORT_TYPE_MISMATCH'
              );

            const actual = state.kind === 1 ? state.pages : state.entries.length;
            const minimum = state.kind === 1 ? e.memory_minimum(target) : e.table_size(target),
              requiredMaximum = state.kind === 1 ? e.memory_maximum(target) : e.table_max(target);

            // Require table element types to agree because imported tables can be both read and written.
            if (
              state.kind === 3 &&
              (!compatibleType(
                state.descriptor,
                typeDescription(view.getInt32(e.table_info(target) + 16, true))
              ) ||
                !compatibleType(
                  typeDescription(view.getInt32(e.table_info(target) + 16, true)),
                  state.descriptor
                ))
            )
              throw importError(
                `import signature mismatch ${module}.${name}`,
                module,
                name,
                'IMPORT_TYPE_MISMATCH'
              );

            // Enforce declared minimum sizes and maximum limits against the provider's actual resource.
            if (
              actual < minimum ||
              (requiredMaximum !== -1 && (state.maximum === -1 || state.maximum > requiredMaximum))
            )
              throw importError(
                `import signature mismatch ${module}.${name}`,
                module,
                name,
                'IMPORT_TYPE_MISMATCH'
              );

            // Bind imported memory with the provider's current size and maximum.
            if (state.kind === 1) check(e.bind_guest_memory(target, actual, state.maximum));
            else check(e.bind_guest_table(target, actual, state.maximum));
          } else if (state.kind === 2) {
            // Bind a global import with its declared mutability and structural value type.
            const globalAt = e.global_info(target);

            // Require global mutability to match; mutable globals also require type compatibility in both directions.
            if (
              state.mutable !== view.getInt32(globalAt + 8, true) ||
              !compatibleType(state.descriptor, typeDescription(view.getInt32(globalAt + 12, true))) ||
              (state.mutable &&
                !compatibleType(typeDescription(view.getInt32(globalAt + 12, true)), state.descriptor))
            )
              throw importError(
                `import signature mismatch ${module}.${name}`,
                module,
                name,
                'IMPORT_TYPE_MISMATCH'
              );
          }

          resourceBindings.push({ index: target, state, publishable: false });
          resolved.push(null);
          continue;
        }

        const params = Array.from(
          { length: e.function_params(target) },
          /**
           * Read one declared import parameter kind.
           *
           * @param {undefined} _
           * @param {number} slot
           * @returns {number}
           */
          (_, slot) => e.function_param_type(target, slot)
        );
        const results = resultSignature(target);

        // Reject missing or noncallable function imports before recording their argument ABI.
        if (typeof callback !== 'function')
          throw importError(`missing function import ${module}.${name}`, module, name, 'MISSING_IMPORT');

        const signature = functionTypes.get(callback);

        // Reject typed forwarding functions whose generation or structural signature is incompatible.
        if (
          signature &&
          (!signature.valid() ||
            signature.params.join(',') !== params.join(',') ||
            JSON.stringify(signature.results) !== JSON.stringify(results) ||
            (signature.descriptor &&
              !compatibleType(signature.descriptor, typeDescription(e.function_heap_type(target)))))
        ) {
          throw importError(
            `import signature mismatch or stale binding ${module}.${name}`,
            module,
            name,
            'IMPORT_TYPE_MISMATCH'
          );
        }

        resolved.push({ module, name, params, results, callback });
      }

      bindings = resolved;
      resources = resourceBindings;

      const globalAliases = new Map();

      // Canonicalize repeated imports of the same mutable global handle.
      // Restrict global aliasing to global imports.
      for (const binding of resources)
        if (binding.state.kind === 2) {
          // Point duplicate imports at the first guest slot so mutations are immediately shared.
          if (globalAliases.has(binding.state))
            e.alias_guest_global(binding.index, globalAliases.get(binding.state));
          else globalAliases.set(binding.state, binding.index);
        }

      const memoryAliases = new Map();

      // Canonicalize repeated imports of the same memory handle.
      // Restrict memory aliasing to memory imports.
      for (const binding of resources)
        if (binding.state.kind === 1) {
          // Reuse the first imported memory descriptor so aliases share storage and growth.
          if (memoryAliases.has(binding.state))
            e.alias_guest_memory(binding.index, memoryAliases.get(binding.state));
          else memoryAliases.set(binding.state, binding.index);
        }

      const tableAliases = new Map();

      // Canonicalize repeated imports of the same table handle.
      // Restrict table aliasing to table imports.
      for (const binding of resources)
        if (binding.state.kind === 3) {
          // Reuse the first imported table descriptor so aliases share entries and growth.
          if (tableAliases.has(binding.state))
            e.alias_guest_table(binding.index, tableAliases.get(binding.state));
          else tableAliases.set(binding.state, binding.index);
        }

      check(e.prepare_resource_imports(pages, maximum, entries, tableMaximum));

      synchronizeIn();

      // Check forwarding depth before running imported callbacks during guest initialization.
      if (backend.countsForwardingDepth && currentDepth() >= limits.forwardingDepth)
        throw new Error('forwarding depth limit');

      // Start callbacks may reenter initialized functions while reloads remain guarded.
      loaded = true;
      invoking = true;
      activeInvocation = { phase: 'initialize', cooperative: asynchronous ? cooperative : undefined };

      /**
       * Finish module initialization and publish its loaded state and resource changes.
       *
       * @returns {void}
       */
      const finish = () => {
        synchronizeOut();
      };

      /**
       * Clear the loaded state and translate an initialization failure for the caller.
       *
       * @param {unknown} error
       * @returns {never}
       */
      const failed = (error) => {
        // Preserve segment writes even when later initialization fails.
        if (e.segments_ready()) synchronizeOut();

        loaded = false;

        throw error;
      };

      /**
       * Restore invocation ownership after guest module initialization.
       *
       * @returns {void}
       */
      const cleanup = () => {
        // Abort a pending initialization import before releasing invocation ownership.
        try {
          // Cancel a still-pending import left by a failed start callback.
          if (activeInvocation?.cooperative && e.execution_paused()) e.cancel_execution();
          else if (e.pending_import() >= 0) e.resume64(0n, 1);
        } finally {
          // Release initialization ownership even when aborting a suspended import fails.
          invoking = false;
          activeInvocation = undefined;
        }
      };

      // Allow the automatic start function to suspend only for an asynchronous load.
      if (asynchronous) {
        const depth = currentDepth() + (backend.countsForwardingDepth ? 1 : 0);

        // Initialize the guest asynchronously and clear invocation state on every exit path.
        return invocationContext.run(
          depth,
          /**
           * Run asynchronous initialization and retain failure/cleanup handling.
           *
           * @returns {Promise<void>}
           */
          async () => {
            // Initialize resources and run the automatic start while guaranteeing cleanup.
            try {
              configureExecution();
              check(e.initialize());
              await driveAsync(0n);
              finish();
            } catch (error) {
              // Clear loaded state and preserve visible segment effects when asynchronous initialization fails.
              failed(error);
            } finally {
              // Release invocation ownership after asynchronous guest initialization.
              cleanup();
            }
          }
        );
      }

      /**
       * Execute the prepared operation within its invocation context.
       *
       * @returns {void}
       */
      const run = () => {
        // Initialize resources and run the automatic start through the synchronous driver.
        try {
          configureExecution();
          check(e.initialize());
          drive(0n);
          finish();
        } catch (error) {
          // Clear loaded state and preserve visible segment effects when synchronous initialization fails.
          failed(error);
        } finally {
          // Release invocation ownership after synchronous guest initialization.
          cleanup();
        }
      };

      return backend.countsForwardingDepth ? invocationContext.run(currentDepth() + 1, run) : run();
    },

    /**
     * Load a text guest while allowing asynchronous imports during initialization.
     *
     * @param {GuestSource} source
     * @param {HostImports} [imports]
     * @returns {Promise<void>}
     */
    async loadAsync(source, imports = {}) {
      return api.load(source, imports, false, true);
    },

    /**
     * Load a binary guest while allowing asynchronous imports during initialization.
     *
     * @param {Uint8Array} bytes
     * @param {HostImports} [imports]
     * @returns {Promise<void>}
     */
    async loadBinaryAsync(bytes, imports = {}) {
      // Require byte-oriented binary input before using the asynchronous binary decoder.
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');

      return api.load(bytes, imports, true, true);
    },

    /**
     * Decode and load a binary guest without compiling it natively.
     *
     * @param {Uint8Array} bytes
     * @param {HostImports} [imports]
     * @returns {void}
     */
    loadBinary(bytes, imports = {}) {
      // Require byte-oriented binary input before using the synchronous binary decoder.
      if (!(bytes instanceof Uint8Array)) throw new Error('binary source must be a Uint8Array');

      api.load(bytes, imports, true);
    },

    /**
     * Invoke a guest export synchronously and return decoded results.
     *
     * @param {string} name
     * @param {...unknown} args
     * @returns {unknown}
     */
    invoke(name, ...args) {
      return invokePublic(name, args, false);
    },

    /**
     * Invoke a guest export while awaiting asynchronous host imports.
     *
     * @param {string} name
     * @param {...unknown} args
     * @returns {Promise<unknown>}
     */
    async invokeAsync(name, ...args) {
      return invokePublic(name, args, true);
    },

    /**
     * Raw async slots also protect Promise externrefs from JavaScript promise assimilation.
     *
     * @param {string} name
     * @param {...RawValue} args
     * @returns {Promise<RawResult>}
     */
    async invokeRawAsync(name, ...args) {
      return invokeRawPublic(name, args, true);
    },

    /**
     * Invoke a guest export with raw typed value slots.
     *
     * @param {string} name
     * @param {...RawValue} args
     * @returns {RawResult}
     */
    invokeRaw(name, ...args) {
      return /** @type {RawResult} */ (invokeRawPublic(name, args, false));
    },

    /**
     * Return bytes reclaimed from the guest's private object arena; collection preserves live reference identity.
     *
     * @returns {number}
     */
    collectGarbage() {
      requireIdle();
      requireLoaded();

      synchronizeIn();

      refreshHostRoots();

      const before = e.gc_live_bytes();

      e.collect_garbage();
      check(e.error_code());

      return before - e.gc_live_bytes();
    },

    /**
     * Return the parameter and result types of a named guest export.
     *
     * @param {string} name
     * @returns {PublicSignature}
     */
    signature(name) {
      const signature = functionSignature(name);

      return {
        params: signature.params.map(
          /**
           * Expose one parameter kind under its public value type name.
           *
           * @param {number} type
           * @returns {ValueTypeName}
           */
          (type) => /** @type {ValueTypeName} */ (scalarNames[type])
        ),
        result: Array.isArray(signature.results)
          ? signature.results.map(
              /**
               * Expose one result kind under its public value type name.
               *
               * @param {number} type
               * @returns {ValueTypeName}
               */
              (type) => /** @type {ValueTypeName} */ (scalarNames[type])
            )
          : /** @type {ValueTypeName} */ (scalarNames[/** @type {number} */ (signature.results)])
      };
    },

    /**
     * Return a typed, generation-bound forwarding function for a guest export.
     *
     * @param {string} name
     * @returns {HostCallback}
     */
    exportFunction(name) {
      requireLoaded();

      const signature = functionSignature(name);

      // Preserve callback identity by reusing an already exported function.
      if (exportedFunctions.has(signature.index)) return exportedFunctions.get(signature.index);

      const existing = tableFunctions.get(signature.index);

      // Reuse this instance's table callback when the function already has a reference wrapper.
      if (existing?.owner === owner) return existing.callback;

      const currentGeneration = generation;

      /**
       * Forward decoded arguments to the referenced guest function.
       *
       * @param {...unknown} args
       * @returns {unknown}
       */
      const callback = (...args) => {
        // Reject decoded forwarding calls after their provider has been reloaded.
        if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

        return api.invoke(name, ...args);
      };

      functionTypes.set(callback, {
        params: signature.params,
        results: signature.results,
        descriptor: typeDescription(e.function_heap_type(signature.index)),

        /**
         * Check that a forwarding handle still belongs to the current loaded generation.
         *
         * @returns {boolean}
         */
        valid: () => loaded && generation === currentGeneration,

        /**
         * Run the operation with raw typed arguments and results.
         *
         * @param {RawValue[]} args
         * @returns {RawResult}
         */
        raw: (args) => {
          // Reject raw forwarding calls after their provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return api.invokeRaw(name, ...args);
        },

        /**
         * Forward raw typed arguments while awaiting asynchronous guest imports.
         *
         * @param {RawValue[]} args
         * @returns {Promise<RawResult>}
         */
        rawAsync: async (args) => {
          // Reject asynchronous raw forwarding calls after their provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return api.invokeRawAsync(name, ...args);
        },

        /**
         * Return the generation-checked guest function reference for this forwarding binding.
         *
         * @returns {FunctionReference}
         */
        reference: () => {
          // Reject reference recovery after the function's provider has been reloaded.
          if (!loaded || generation !== currentGeneration) throw new Error('stale forwarded function');

          return functionReference(signature.index);
        }
      });
      exportedFunctions.set(signature.index, callback);

      return callback;
    },

    /**
     * Return a forwarding function that supports asynchronous guest imports.
     *
     * @param {string} name
     * @returns {AsyncHostCallback}
     */
    exportFunctionAsync(name) {
      const synchronous = api.exportFunction(name);

      // Reuse the asynchronous wrapper for a previously exported synchronous function.
      if (asynchronousFunctions.has(synchronous)) return asynchronousFunctions.get(synchronous);

      const metadata = /** @type {FunctionMetadata} */ (functionTypes.get(synchronous));

      /**
       * Forward decoded arguments to the referenced guest function.
       *
       * @param {...unknown} args
       * @returns {Promise<unknown>}
       */
      const callback = async (...args) => {
        // Reject asynchronous forwarding calls whose original export is stale.
        if (!metadata.valid()) throw new Error('stale forwarded function');

        return api.invokeAsync(name, ...args);
      };

      functionTypes.set(callback, metadata);
      asynchronousFunctions.set(synchronous, callback);
      asynchronousImports.add(callback);

      return callback;
    },

    /**
     * Build an export namespace whose functions permit asynchronous invocation.
     *
     * @returns {HostNamespace}
     */
    exportNamespaceAsync() {
      return api.exportNamespace(true);
    },

    /**
     * Build a namespace of forwarding functions and resource handles.
     *
     * @param {boolean} [asynchronous]
     * @returns {HostNamespace}
     */
    exportNamespace(asynchronous = false) {
      requireLoaded();

      synchronizeIn();

      const namespace = Object.create(null);

      // Expose every named guest export as a typed callback or resource handle.
      for (let index = 0; index < e.exports_count(); index++) {
        const view = new DataView(e.memory.buffer, memoryOffset),
          at = e.export_info(index);
        const name = readText(view.getUint32(at, true), view.getUint32(at + 4, true));
        const target = view.getInt32(at + 8, true),
          kind = view.getInt32(at + 20, true);

        namespace[name] = kind
          ? exportResource(target, kind)
          : asynchronous
          ? api.exportFunctionAsync(name)
          : api.exportFunction(name);
      }

      return namespace;
    },

    /**
     * Read the declared scalar, vector or reference kind of an exported global.
     * @param {string} name
     * @returns {ValueTypeName}
     */
    globalType(name) {
      requireLoaded();
      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);

      check(e.error_code());

      return /** @type {ValueTypeName} */ (scalarNames[type]);
    },

    /**
     * Read and decode a named guest global, preserving vector and reference values.
     *
     * @param {string} name
     * @returns {unknown}
     */
    getGlobal(name) {
      synchronizeIn();

      requireLoaded();

      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);

      check(e.error_code());

      let value = e.get_global64(at, n);

      // Include both halves when reading a vector global.
      if (type === 7) value = BigInt.asUintN(64, value) | (BigInt.asUintN(64, e.global_high(at, n)) << 64n);

      check(e.error_code());

      return decodedValue(value, type);
    },

    /**
     * Validate and publish a new value for a mutable guest global.
     *
     * @param {string} name
     * @param {unknown} value
     * @returns {void}
     */
    setGlobal(name, value) {
      synchronizeIn();

      requireLoaded();

      const at = e.host_base();
      const n = write(name, at);
      const type = e.global_type(at, n);

      check(e.error_code());

      const bits = typedValue(value, type);

      // Foreign function interning uses host scratch; restore the global name afterward.
      write(name, at);
      check(e.set_global64(at, n, BigInt.asIntN(64, bits)));

      // Write the upper half as well as the low slot when assigning a vector global.
      if (type === 7) check(e.set_global_high(at, n, BigInt.asIntN(64, bits >> 64n)));

      synchronizeOut();
    },

    /**
     * Copy a checked range of guest memory into host-owned bytes.
     *
     * @param {number | bigint} offset
     * @param {number} length
     * @param {ResourceSelector} [memory]
     * @returns {Uint8Array}
     */
    readMemory(offset, length, memory = 0) {
      synchronizeIn();

      const at = memoryRange(offset, length, memoryIndex(memory));

      return new Uint8Array(e.memory.buffer, memoryOffset + at, length).slice();
    },

    /**
     * Copy host bytes into a checked range of guest memory and publish changes.
     *
     * @param {number | bigint} offset
     * @param {Uint8Array} bytes
     * @param {ResourceSelector} [memory]
     * @returns {void}
     */
    writeMemory(offset, bytes, memory = 0) {
      synchronizeIn();

      // Require a byte array before copying host data into guest memory.
      if (!(bytes instanceof Uint8Array)) throw new Error('memory bytes must be a Uint8Array');

      const at = memoryRange(offset, bytes.length, memoryIndex(memory));

      new Uint8Array(e.memory.buffer, memoryOffset + at, bytes.length).set(bytes);

      synchronizeOut();
    },

    /**
     * Page counts remain Numbers because host-visible physical backing is bounded.
     *
     * @param {ResourceSelector} [memory]
     * @returns {AddressType}
     */
    memoryType(memory = 0) {
      requireLoaded();

      return e.memory_width(memoryIndex(memory)) === 2 ? 'i64' : 'i32';
    },

    /**
     * Read the current logical page count of a selected guest memory.
     *
     * @param {ResourceSelector} [memory]
     * @returns {number}
     */
    memoryPages(memory = 0) {
      synchronizeIn();

      return e.memory_pages(memoryIndex(memory));
    },

    /**
     * Grow a selected guest memory, returning its previous size or failure.
     *
     * @param {number | bigint} pages
     * @param {ResourceSelector} [memory]
     * @returns {number}
     */
    growMemory(pages, memory = 0) {
      synchronizeIn();

      const index = memoryIndex(memory);

      // Preserve a memory64 growth delta as a BigInt until its logical range has been checked.
      if (typeof pages === 'bigint') {
        // Prevent BigInt growth requests from being used with memory32.
        if (e.memory_width(index) !== 2) throw new Error('BigInt growth requires memory64');

        // Reject growth deltas outside the unsigned memory64 address range.
        if (pages < 0n || pages > (1n << 64n) - 1n) throw new Error('pages must be an unsigned i64 integer');

        // Large logical deltas must fail without narrowing or wrapping the host ABI's i32 slot.
        if (pages > 0xffffffffn) return -1;

        pages = Number(pages);
      }

      u32(pages);

      const result = e.grow_memory(index, pages);

      synchronizeOut();

      return result;
    },

    /**
     * Return a checked, generation-bound guest tag handle.
     *
     * @param {ResourceSelector} [tag]
     * @returns {TagHandle}
     */
    getTag(tag = 0) {
      return /** @type {TagHandle} */ (exportResource(tagIndex(tag), 4));
    },

    /**
     * Return the parameter types of a selected guest tag.
     *
     * @param {ResourceSelector} [tag]
     * @returns {TagSignature}
     */
    tagSignature(tag = 0) {
      return {
        params: tagParameters(tagIndex(tag)).map(
          /**
           * Expose one tag parameter under its public value type name.
           *
           * @param {number} type
           * @returns {ValueTypeName}
           */
          (type) => /** @type {ValueTypeName} */ (scalarNames[type])
        )
      };
    },

    /**
     * Validate a tag payload and create a host-visible guest exception.
     *
     * @param {ResourceSelector} tag
     * @param {...unknown} args
     * @returns {WiwException}
     */
    createException(tag, ...args) {
      return createException(tag, args, false);
    },

    /**
     * Create a tagged guest exception from raw typed payload slots.
     *
     * @param {ResourceSelector} tag
     * @param {...RawValue} args
     * @returns {WiwException}
     */
    createExceptionRaw(tag, ...args) {
      return createException(tag, args, true);
    },

    /**
     * Read the current logical element count of a selected guest table.
     *
     * @param {ResourceSelector} [table]
     * @returns {number}
     */
    tableSize(table = 0) {
      synchronizeIn();

      return e.table_size(tableIndex(table));
    },

    /**
     * Read and decode a checked guest table element.
     *
     * @param {number | bigint} index
     * @param {ResourceSelector} [table]
     * @returns {unknown}
     */
    getTable(index, table = 0) {
      synchronizeIn();

      const target = tableIndex(table),
        slot = tableEntry(index, target);
      const at = e.table_base(target) + slot * 4;
      const bits = BigInt((new DataView(e.memory.buffer, memoryOffset).getUint32(at, true) + 1) >>> 0);

      return decodedValue(bits, e.table_type(target));
    },

    /**
     * Validate and publish a replacement guest table element.
     *
     * @param {number | bigint} index
     * @param {unknown} value
     * @param {ResourceSelector} [table]
     * @returns {void}
     */
    setTable(index, value, table = 0) {
      synchronizeIn();

      const target = tableIndex(table),
        slot = tableEntry(index, target);
      const bits = tableValue(value, target);

      // Reference interning can move backing memory, so obtain the entry address afterward.
      new DataView(e.memory.buffer, memoryOffset).setInt32(
        e.table_base(target) + slot * 4,
        Number(bits) - 1,
        true
      );

      synchronizeOut();
    },

    /**
     * Grow a guest table with a compatible fill value, returning its previous size or failure.
     *
     * @param {number | bigint} entries
     * @param {unknown} [value]
     * @param {ResourceSelector} [table]
     * @returns {number}
     */
    growTable(entries, value = null, table = 0) {
      synchronizeIn();

      const target = tableIndex(table);
      let oversized = false;

      // Preserve table64 growth deltas until their logical range has been checked.
      if (typeof entries === 'bigint') {
        // Prevent BigInt growth requests from being used with table32.
        if (e.table_address_type(target) !== 2) throw new Error('BigInt growth requires table64');

        // Reject growth deltas outside the unsigned table64 address range.
        if (entries < 0n || entries > (1n << 64n) - 1n)
          throw new Error('entries must be an unsigned i64 integer');

        oversized = entries > 0xffffffffn;
        entries = oversized ? 0 : Number(entries);
      }

      u32(entries);

      const bits = tableValue(value, target);

      // Report physically unrepresentable table growth without wrapping the requested size.
      if (oversized) return -1;

      const result = e.grow_host_table(target, entries, bits);

      synchronizeOut();

      return result;
    },

    /**
     * Enable cooperative async dispatch and optional AbortSignal cancellation; null restores ordinary execution.
     *
     * @param {CooperativeOptions | null} [options]
     * @returns {InterpreterApi}
     */
    setCooperativeExecution(options = {}) {
      requireIdle();

      // Explicit disabling leaves synchronous and asynchronous calls on the existing driver contract.
      if (options === null) {
        cooperative = undefined;

        return api;
      }

      hostResourceOptions(options, ['quantum', 'signal'], 'cooperative execution');

      const { quantum = 10000, signal } = options;

      // The quantum is an instruction-fuel target rather than a wall-clock deadline.
      if (!Number.isInteger(quantum) || quantum < 1 || quantum > 0xffffffff)
        throw new Error('quantum must be an integer from 1 to 4294967295');

      // Native signals provide reason and aborted state without user-defined awaitable behavior.
      if (signal !== undefined && !(signal instanceof AbortSignal))
        throw new Error('signal must be an AbortSignal');

      cooperative = Object.freeze({ quantum, signal });

      return api;
    },

    /**
     * Set the unsigned 32-bit instruction budget for subsequent guest invocations.
     *
     * @param {number} limit
     * @returns {void}
     */
    setFuel(limit) {
      // Reject fuel budgets that cannot be represented as an unsigned i32.
      if (!Number.isInteger(limit) || limit < 0 || limit > 4294967295) {
        throw new Error('fuel must be an unsigned i32 integer');
      }

      e.set_fuel(limit);
    },

    /**
     * Set the unsigned 64-bit instruction budget for subsequent guest invocations.
     *
     * @param {bigint} limit
     * @returns {void}
     */
    setFuel64(limit) {
      // Reject fuel budgets that cannot be represented as an unsigned i64 BigInt.
      if (typeof limit !== 'bigint' || limit < 0n || limit > (1n << 64n) - 1n) {
        throw new Error('fuel must be an unsigned i64 BigInt');
      }

      e.set_fuel64(BigInt.asIntN(64, limit));
    }
  };

  engineBackends.set(api, backend);

  return api;
}

/**
 * Format a result for either frontend while retaining signed zero and the complete vector width.
 *
 * @param {unknown} value
 * @param {ValueTypeName} type
 * @returns {string}
 */
export function formatValue(value, type) {
  // A lane-independent hex pattern exposes both vector halves without interpreting them as an integer result.
  if (type === 'v128')
    return `0x${BigInt.asUintN(128, /** @type {bigint} */ (value))
      .toString(16)
      .padStart(32, '0')}`;

  // Display opaque references without exposing instance-owned handles; null remains distinguishable.
  if (type.endsWith('ref')) return value === null ? 'null' : '<opaque reference>';

  return Object.is(value, -0) ? '-0' : String(value);
}
