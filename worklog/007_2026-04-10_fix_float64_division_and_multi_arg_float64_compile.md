## 2026-04-10 — Fix Float64 division and multi-arg Float64 compile (Bennett-dqc)

### Root cause analysis

The bug was NOT an extractvalue lowering issue (as the ticket described). It was a
**Julia inlining failure** in the SoftFloat dispatch chain.

**What happens:**
1. `reversible_compile(f, Float64, Float64)` creates a wrapper:
   `wrapper(a::UInt64, b::UInt64) = f(SoftFloat(a), SoftFloat(b)).bits`
2. Julia compiles `wrapper` and sees `f(SoftFloat, SoftFloat)` — a call to the
   user's function with struct arguments.
3. Julia's inliner decides NOT to inline `f` because the callee chain is too deep
   (`f → SoftFloat./ → soft_fdiv`, where `soft_fdiv` is 140+ lines).
4. LLVM emits struct-passing ABI: `alloca [1 x i64]` + `store` + `call @j_f_NNN(ptr, ptr)`.
5. `ir_extract.jl` skips `alloca`/`store`, skips the call (ptr args, not in callee
   registry), and the extractvalue on the call result references an undefined SSA var.
6. Error: "Undefined SSA variable: %__v3"

**Why single-arg Float64 used to work:** Julia previously inlined the single-arg
wrapper chain. This may have been marginal — the `@inline` on SoftFloat methods
helps but isn't sufficient for all Julia/LLVM versions.

**Why +, *, - work but / doesn't:** For +, *, -, Julia inlines `SoftFloat.+(a,b) →
soft_fadd(a.bits, b.bits)` and the struct is eliminated. For /, `soft_fdiv` is
much larger (56-iteration restoring division loop), so the inliner gives up.

### Fix: `@inline` at the call site

The fix is simple: use `@inline f(...)` at the call site in the wrapper. This is a
Julia 1.7+ feature that forces the compiler to inline the callee, regardless of
the inliner's cost model. The entire chain then inlines:
`wrapper → f → SoftFloat./ → soft_fdiv`, and LLVM sees only integer operations
with direct `call @j_soft_fdiv` instructions that the callee registry recognizes.

**Changes:**
1. `src/Bennett.jl`: Single variadic `reversible_compile(f, Float64...)` method
   replacing the single-arg-only version. Uses `@inline f(...)` at the call site.
   Handles 1, 2, or 3 Float64 arguments.
2. `src/Bennett.jl`: Added `@inline` to all SoftFloat operator methods (belt and
   suspenders — the call-site @inline is sufficient, but method-level @inline
   ensures consistent behavior across Julia versions).
3. `test/test_float_circuit.jl`: Added Float64 division end-to-end test (62 tests:
   11 edge cases + 50 random + 1 reversibility check).

### Gate counts

| Function | Total | NOT | CNOT | Toffoli |
|----------|-------|-----|------|---------|
| soft_fdiv (direct) | 412,388 | 20,788 | 280,778 | 110,822 |
| Float64 x/y (end-to-end) | 412,388 | 20,788 | 280,778 | 110,822 |
| Float64 x²+3x+1 (regression check) | 717,690 | 20,390 | 440,380 | 256,920 |

soft_fdiv is ~1.56x soft_fmul (265K) and ~4.4x soft_fadd (94K). The 56-iteration
restoring division loop dominates — each iteration is ~7K gates.

### Gotchas

1. **NaN sign bit is implementation-defined.** `0/0` and `Inf/Inf` both produce NaN.
   Our soft_fdiv returns `+NaN` (0x7ff8...) while Julia's hardware division returns
   `-NaN` (0xfff8...). IEEE 754 §6.2 says NaN sign is not specified. Tests must
   compare with `isnan()` for NaN-producing inputs, not bit-exact equality.

2. **`reinterpret(UInt64, x::Int64)` vs `UInt64(x::Int64)`.** The simulator returns
   `Int64`. `UInt64(negative_int64)` throws `InexactError`. Must use `reinterpret`
   for bit-pattern preservation. Same gotcha as in the branchless soft_fadd session.

3. **Julia closure scoping.** `wrapper(a,b) = ...` defined inside an `if` block can
   have scoping issues in Julia 1.12. Use lambda `(a,b) -> ...` instead.

4. **`@inline` at call site vs on function.** `@inline` on the SoftFloat operator
   definitions tells the inliner "prefer to inline this." `@inline f(args...)` at
   the call site tells the inliner "MUST inline this call." The call-site version
   is the one that actually solves the problem — the method-level annotation alone
   isn't enough for deep call chains.

### Full test suite: all tests pass (300 float circuit + all prior tests)

---

## 2026-04-10 — Trivial opcodes + fptosi (Bennett-0p0, Bennett-uky, Bennett-3wj, Bennett-777)

### New opcodes in ir_extract.jl

| Opcode | Expansion | Gates | Notes |
|--------|-----------|-------|-------|
| bitcast | IRCast(:trunc) same-width identity | 66 (roundtrip) | Wire aliasing, zero actual gates |
| fneg | XOR sign bit (typemin(Int64) for double) | 580 | Gotcha: UInt64(1)<<63 overflows Int64 |
| llvm.fabs | AND with typemax(Int64) mask | 576 | Clears sign bit |
| fptosi | IRCall to soft_fptosi | 18,468 | Full IEEE 754 decode, not a bitcast |

### soft_fptosi: IEEE 754 → integer conversion

New branchless function in `src/softfloat/fptosi.jl`. Algorithm:
1. Extract sign, exponent, mantissa
2. Add implicit 1-bit for normal numbers
3. Compute shift: right_shift = 1075 - exp (truncates fractional part)
4. If exp >= 1075: shift left instead (large values)
5. Apply sign via two's complement negation

Key insight: `fptosi` is NOT a bitcast. The WORKLOG's prior session treated it as
identity on bits, which is wrong. `fptosi double 3.0 to i64` should produce `3`,
not `0x4008000000000000` (the IEEE 754 encoding of 3.0).

### Float64 parameter handling in ir_extract.jl

Added `FloatingPointType` support in `_module_to_parsed_ir` parameter extraction.
Float64 params are treated as 64-bit wire arrays, same as UInt64. This allows
direct compilation of `f(x::Float64)` without SoftFloat wrapping.

### Gotchas

1. **typemin(Int64) for sign bit.** `Int(UInt64(1) << 63)` throws InexactError.
   Use `typemin(Int64)` (= -2^63 = 0x8000...0 in two's complement).

2. **fptosi is not bitcast.** The prior session's handling (IRCast identity) was
   wrong. Must route through soft_fptosi for actual value conversion.

3. **Tuple{Float64} vs Float64 varargs.** `reversible_compile(f, Float64)` wraps
   in SoftFloat (for pure-float functions). `reversible_compile(f, Tuple{Float64})`
   compiles directly (for mixed Float64→Int functions).

### Opcode audit: 30/30 functions compile

All 30 audit functions now compile to verified reversible circuits.

---

## 2026-04-10 — Session 3: Opcode audit → Enzyme-class roadmap

### Issues closed this session: 12

| # | Issue | What | Gate count |
|---|---|---|---|
| 1 | Bennett-dqc | Float64 division (multi-arg SoftFloat + @inline) | 412,388 |
| 2 | Bennett-0p0 | bitcast opcode (wire aliasing) | 66 |
| 3 | Bennett-uky | fneg opcode (XOR sign bit) | 580 |
| 4 | Bennett-3wj | fabs intrinsic (AND mask) | 576 |
| 5 | Bennett-au8 | expect/lifetime/assume (deferred — not in IR) | — |
| 6 | Bennett-777 | fptosi via soft_fptosi (IEEE 754 decode) | 18,468 |
| 7 | Bennett-qkj | fcmp 6 predicates (ole, une, ogt, oge) | 5.5–10K |
| 8 | Bennett-chr | SSA-level liveness analysis | — |
| 9 | Bennett-8n5 | T-count and T-depth metrics | — |
| 10 | Bennett-yva | SHA-256 round function benchmark | 17,712 |
| 11 | Bennett-e1s | Cuccaro in-place adder (use_inplace=true) | — |
| 12 | Bennett-1la | sitofp via soft_sitofp (IEEE 754 encode) | 27,930 |

### Key results

**SHA-256 round function:** 17,712 gates, T-count=30,072, T-depth=88, 5,505 ancillae.
Verified correct for 2 consecutive rounds against initial hash values.

**Cuccaro in-place integration:** `lower(parsed; use_inplace=true)` routes
dead-operand additions through Cuccaro adder.
- x+3 (Int8): 33→18 wires (45% reduction)
- Polynomial: 257→227 wires (12% reduction)
- Trades ~15% more gates for significantly fewer ancillae

**soft_sitofp:** Branchless Int64→Float64 conversion, 27,930 gates.
Gotcha: CLZ shift is `clz` not `clz+1` — MSB goes to bit 63, mantissa is [62:11].

**soft_fptosi:** 18,468 gates. Key insight: fptosi is NOT a bitcast — it decodes
IEEE 754 exponent/mantissa to extract the integer value.

**@inline at call site:** The critical fix for Float64 division. Julia's inliner
won't inline through SoftFloat dispatch for large callees (soft_fdiv = 140+ lines).
`@inline f(...)` at the call site forces inlining.

### New infrastructure

- `compute_ssa_liveness(parsed)`: SSA-level last-use detection for each variable
- `_ssa_operands(inst)`: dispatches on all 13 IR instruction types
- `t_count(circuit)`: Toffoli × 7 T-gates
- `t_depth(circuit)`: longest Toffoli chain

### Issues filed: 24 new issues covering Pillar 1-3 + Enzyme-class roadmap

All filed in beads, covering: remaining opcodes, space optimization pipeline
(liveness → Cuccaro → wire reuse → pebbling), benchmarks (SHA-2, arithmetic,
sorting, Float64), composability (Sturm.jl, inline control), ecosystem
(docs, CI, package registration).

### Gate count reference (new entries)

| Function | Width | Gates | T-count | Wires | Ancillae |
|----------|-------|-------|---------|-------|----------|
| bitcast roundtrip | i64 | 66 | 0 | | |
| fneg (reinterpret) | i64 | 580 | 0 | | |
| fabs (reinterpret) | i64 | 576 | 0 | | |
| soft_fptosi | i64 | 18,468 | | | |
| soft_sitofp | i64 | 27,930 | | | |
| fcmp ole | i64 | 10,108 | | | |
| fcmp une | i64 | 5,582 | | | |
| Float64 x/y | i64 | 412,388 | | | |
| SHA-256 round | i32×10 | 17,712 | 30,072 | 5,889 | 5,505 |
| SHA-256 ch | i32×3 | 546 | 1,344 | | |
| SHA-256 maj | i32×3 | 418 | 896 | | |
| SHA-256 sigma0 | i32 | 7,108 | 10,668 | | |

### Handoff for next session

**Remaining P1 (1 issue):**
- Bennett-an5: Full pebbling pipeline (the big one — DAG + Knill + wire reuse)

**Remaining P2 (12 issues):**
- Bennett-47k: Activity analysis (dead-wire elimination during lowering)
- Bennett-6yr: PRS15 EAGER Algorithm 2 (MDD-level uncomputation)
- Bennett-i5c: Wire reuse in Phase 3
- Bennett-qef: Karatsuba multiplier
- Bennett-bzx: Arithmetic benchmark suite
- Bennett-der: Sorting network benchmark
- Bennett-dpk: Float64 benchmark vs Haener 2018
- Bennett-kz1: BENCHMARKS.md
- Bennett-5ye: Sturm.jl integration
- Bennett-89j: Inline control during lowering
- Bennett-cc0: store instruction
- Bennett-dbx: Variable-index GEP

**Critical dependency chain:**
```
Wire Reuse (i5c) → PRS15 EAGER (6yr) → Pebbling Pipeline (an5)
```

### fcmp predicate coverage

Added 6 fcmp predicates: olt, oeq (existing), ole, une (new), ogt/oge (swap+existing).
Routes through soft_fcmp callees. Gate counts: ole=10,108, une=5,582.

### Issues deferred after research

- **Bennett-36m** (overflow intrinsics): Not found in optimized Julia IR. Julia handles
  overflow at the Julia level, LLVM sees plain `add`/`sub`/`mul`.
- **Bennett-tfx** (frem): Not found in optimized Julia IR. Julia calls libm `fmod`.

### Session totals

**7 issues closed this session:**
- Bennett-dqc: Float64 division (multi-arg SoftFloat + @inline fix)
- Bennett-0p0: bitcast opcode
- Bennett-uky: fneg opcode
- Bennett-3wj: fabs intrinsic
- Bennett-au8: expect/lifetime/assume (deferred — not in IR)
- Bennett-777: fptosi (soft_fptosi IEEE 754 decode)
- Bennett-qkj: fcmp predicates (ole, une, ogt, oge)

**2 issues deferred:** Bennett-36m, Bennett-tfx

**New opcode coverage:** bitcast, fneg, fabs, fcmp (6 predicates), fptosi → soft_fptosi
**Audit milestone: 30/30 functions compile to verified reversible circuits.**

---

