**Confirmed findings — all RAN**

1. **9198a7a — [instructions.jl:5009](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/instructions.jl:5009):** Overflow intrinsics are omitted from width-dependent provenance, allowing source-width overflow thresholds to survive narrowing.  
   Example: hand-written IR computes `llvm.umul.with.overflow.i8(%x, 16)`, extracts the flag, and returns it as i8. Extract with `ptr_cells=true`, then narrow to seven bits: input **8 → 0**, whereas native `llvm.umul.with.overflow.i7(8,16)` returns **1**. Verification passes; both narrowed readings agree.  
   **Fix property:** recompute overflow at W or refuse the expansion; agreement must not certify a shared stale threshold.

2. **a83fe6b — [tabulate.jl:401](/home/tobiasosborne/Projects/Bennett-slots/s0/src/tabulate.jl:401):** `inaccessiblememonly` admits nondeterministic reads of uninitialized local memory.  
   Example: `@noinline alloc(n)=Vector{UInt8}(undef,n)`; `f(x::UInt8)=alloc(1000)[1] ⊻ x`. With `strategy=:tabulate`, input **0 → 8** in the table; subsequent native calls after allocation churn returned **57** and other values. Verification passes.  
   **Fix property:** certify deterministic results, including initialization of locally read memory.

3. **2cd65f2 — [Bennett.jl:660](/home/tobiasosborne/Projects/Bennett-slots/s0/src/Bennett.jl:660):** The differential check withdraws correct existing narrowing support, and the corresponding acceptance assertion was replaced with a refusal assertion.  
   Example: `f(x::UInt8)=ifelse(x*UInt8(16)==0x00,0x01,0x00)`, `bit_width=6`. At d40f321, all 64 inputs match the W-bit oracle and verification passes; input **4 → 1**. Current compilation throws. [The test now expects refusal](/home/tobiasosborne/Projects/Bennett-slots/s0/test/test_koi8_narrow_folded_cmp.jl:161). This is deliberate, but meets your regression definition.  
   **Fix property:** preserve correct supported programs and their acceptance assertions while preventing source-width folds from determining W-bit behavior.

4. **f2ae03f — [module_walk.jl:1197](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/module_walk.jl:1197):** The synthetic-byte guard also rejects genuine zero bytes representing a null pointer.  
   Example: `@g = constant {i64,ptr} {i64 1,ptr null}`; GEP to byte 15 and load i8. Input **42 → 0** in native LLVM and at d40f321, with verification passing; current extraction throws `Bennett-0cnv`.  
   **Fix property:** distinguish synthetic addresses from faithfully represented null-pointer bytes.

**Unconfirmed concerns:** none retained.

- **3328319 — no finding:** checked three-member Unions including `Missing`, nested tuples, `Some`, SoftFloat-specific methods, and Union-typed callables.
- **95b2d9c — no finding:** 3,696 accepted promotion cases passed independent edge/range checks and verification; inspected cross-block, phi, call, select, truncation, and mixed-source-width uses.
- **5952275 — no finding:** checked cross-block and back-edge cases, pointer round trips/escapes, calls, self-copy, atomic/volatile stores, and pointer vectors.
- **2ea8d0c — no finding:** all three additions are redundant interrupt rethrows; handled exception classes remain unchanged.

Other targeted checks passed: comparison argument/bit order, raw outputs, loop failures, deterministic sampling, caches across valid strategies/memory options, field propagation, two/three arguments, and W=S. Global overlap, nested-pointer, packed/i24 stride, and endian probes produced correct results or refusals. No files changed.