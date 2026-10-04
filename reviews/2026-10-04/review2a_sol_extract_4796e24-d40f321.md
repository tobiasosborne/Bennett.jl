**Confirmed — EXECUTED**

1. **8dfd87d / Bennett-omhx — [module_walk.jl:1109](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/module_walk.jl:1109):** Newly admitted alias-containing structs expose synthetic pointer bytes through global GEP loads, bypassing the memcpy escape guard.

   Witness:
   ```llvm
   target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
   @h = private constant i8 7
   @alias = private alias i8, ptr @h
   @g = private constant {ptr} {ptr @alias}
   define i8 @f(i8 %x) {
     %q = getelementptr i8, ptr @g, i64 7
     %v = load i8, ptr %q
     ret i8 %v
   }
   ```
   Input `42` → Bennett **16**, native LLVM **0**; `verify_reversibility=true`. The old flattening function refuses the same witness.
   **Invariant:** Every read of synthetic pointer bytes must preserve their restricted provenance or fail loudly, including constant and runtime global GEP reads.

2. **b5b5698 / Bennett-fpa0 — [module_walk.jl:1056](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/module_walk.jl:1056):** Struct array fields use store size as element stride, corrupting flattened bytes when DataLayout pads elements; **also present at 4796e24**.

   Witness: DataLayout `e-m:e-i32:64-i64:64-n8:16:32:64-S128`, global `@g = constant { [2 x i32] } { [2 x i32] [i32 1, i32 2] }`; memcpy 16 bytes into `[16 x i8]`, then load byte 8.
   Input `42` → **0**, LLVM semantics require **2**; `verify_reversibility=true`. Replaying the old flattening function also returns 0.
   **Invariant:** Array-element placement must use DataLayout allocation stride; only the element’s stored bytes are copied.

**Suspicion — extraction EXECUTED; downstream result unverified**

3. **862b4b1 / Bennett-ni9i — [instructions.jl:4651](/home/tobiasosborne/Projects/Bennett-slots/s0/src/extract/instructions.jl:4651):** Freshness treats an unresolved bulk-write destination as disjoint, allowing a selected alloca alias to evade certification.

   Witness under `ptr_cells=true`: `%p = alloca i8, i32 4`; `%q = select i1 %c, ptr %p, ptr %p`; variable-length `memset(%q,42,zext(%x))`; constant `memset(%p,0,4)`; load `%p`.
   Input `4` → native **0**; extracted IR retains the fill with 42 and deletes the zero-fill, implying **42** under the emitted memory semantics. Circuit lowering refuses the Symbol-callee `memset`; BennettVM execution remains unverified.
   **Invariant:** Freshness must reject every potentially aliasing write unless disjointness is proved, including phi/select-derived destinations and unknown call arguments.

**Clean**

- **32b7011 / 0ucg:** clean — probed padded/packed structs, vector allocation sizes, arrays of structs, negative i8/i32 and wide indices; inspected runtime refusals and float stamps.
- **f5e7a04 / uiqq + 1zow:** clean — probed signed/overflowing counts and annotation-only allocas; audited all 14 re-pins without finding removed correct-result assertions.
- **7b4192a / 1qws:** clean — probed vector f64 rounding, f32/f16 refusals, round/roundeven neighbours, and loud nearbyint rejection.
- **d40f321 / q3fa:** clean — probed cross-block producers, shared consumers, returned poison/undef, shape-changing bitcasts, and overlapping scalar/vector stores; reverse block order remains refused.