**Confirmed — EXECUTED**

1. **f0b374d — [src/extract/callees.jl:279](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/callees.jl:279):** The hybrid accepts unoptimized expansions of width-dependent operations and produces wrong circuits.

   ```julia
   f(x::UInt8) = ifelse(bitreverse(x) == 0x00, 0x01, 0x00)
   c = reversible_compile(f, UInt8; bit_width=7)
   ```

   Input `0x10` → circuit `0x01`, expected/native `0x00`; seven of 128 inputs fail, while `verify_reversibility(c)` returns `true`. The legacy optimized path computes all 128 correctly. Neighbors: `ctlz_int(0)` and `cttz_int(0)` return 8 instead of the W-bit count 7.
   
   **Invariant:** Preserve provenance of width-dependent expansions; regenerate them at W or refuse the unoptimized attempt.

2. **46cce7e — [src/Bennett.jl:340](/home/tobiasosborne/Projects/Bennett-slots/s0/src/Bennett.jl:340), pre-existing neighbor:** A singleton callable reading mutable global state passes validation and `:tabulate` silently freezes that state.

   Witness: `const cell=Ref(Int8(3)); struct Stateless end; (::Stateless)(x::Int8)=x+cell[]`. Compile with `strategy=:tabulate`, then set `cell[]=9`: input 1 → circuit 4, native 10; verification passes. **This predates 46cce7e.**
   
   **Invariant:** Tabulation must reject external mutable dependencies, including those accessed by singleton callables.

**Suspicion — READ**

3. **f0b374d — [src/extract/callees.jl:291](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/callees.jl:291):** Every `ErrorException` triggers fallback, including internal invariant failures.

   `ErrorException("internal CFG invariant broken")` → classified as a refusal, expected propagation. Classification was executed; an actual extractor failure being hidden was not reproduced.
   
   **Invariant:** Only explicitly typed capability refusals may trigger fallback.

**Clean**

- **d0b0601 — clean:** width-changing seams, multiple guards at front/middle/end, repeated objects, self-cleaning stages, overlapping-wire rejection, zero/one-stage calls, controlled composition.
- **1fde3d6 — clean:** exponent boundaries, huge exponents, negative powers, special paths, IEEE edges, 10,000 random bit comparisons.
- **d9fe058 — clean:** replacing the hint with its old behavior preserved gates and wires across five explicit arithmetic strategies.
- **0abc3d1 — clean:** nested callees with compact calls, Cuccaro/QCLA, unfolded constants, persistent memory and hashcons options; inspected all five memory guard-forwarding sites.
- **ed9dca1 — clean:** nested callee guards retain K=64; over-bound inputs fail loudly under the tested option combinations.
- **101e1bd — clean:** invalid targets rejected; explicit strategies retained identical gates and correct results across targets.
- **e30c12f — clean:** guarded both-none calls and intrinsic calls fail loudly downstream; ordinary Float64 and bit-reinterpretation probes retained correct results.