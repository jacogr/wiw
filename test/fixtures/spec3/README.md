These `.hex` files encode the corresponding readable `.wat` fixtures. Keeping the
bytes checked in avoids requiring GC text support from WABT. They were emitted
with Binaryen 125 `wasm-as --all-features --disable-custom-descriptors` and are
independently validated and executed by Node in `spec3.test.js`. Custom descriptors
are excluded because they are outside the `wg-3.0` pin. The exception oracle uses
Node's `--experimental-wasm-exnref` flag when required; wiw itself does not need that flag.
