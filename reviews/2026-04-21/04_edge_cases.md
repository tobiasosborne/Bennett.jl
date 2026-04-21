# Bennett.jl Edge-Case & Adversarial Input Review — 2026-04-21

**Reviewer role:** Independent security/QA, skeptical, harsh.
**Scope:** Edge cases and adversarial inputs across integer arithmetic,
control flow, soft-float, LLVM IR quirks, width coercion, persistent DS,
wire allocator.

All findings below are reproduced with probes (`julia --project -e '…'`)
in the current working tree. Line numbers are 1-based from the file path
at the head of each finding.

---

## TL;DR — Most important findings

1. **CRITICAL — `lower_loop!` silently drops body blocks when the loop
   body is not merged into the header.** With `optimize=false`
   (which CLAUDE.md §5 mandates for predictable IR), any `while` loop whose
   body lives in a distinct basic block produces
   `Undefined SSA variable: %__vN`. The code path is untested because every
   loop test uses either a constant range (LLVM fully unrolls) or a form
   Julia flattens into the header. `src/lower.jl:692-782`.
2. **CRITICAL — Soft-float is not bit-exact with hardware for NaN
   inputs.** All `soft_fadd`, `soft_fmul`, `soft_fdiv`, `soft_fsqrt` erase
   the input NaN's sign and payload and return the canonical
   `0x7FF8000000000000`. IEEE 754-2008 §6.2.3 requires payload
   propagation; `CLAUDE.md §13` says "bit-exact with hardware".
3. **HIGH — `reversible_compile`'s default is `optimize=true`** but
   `CLAUDE.md §5` mandates `optimize=false` for predictability. The loop
   bug in (1) is hidden by this default because `optimize=true` lets
   LLVM fold simple loops into branchless `select`. `src/Bennett.jl:59,269`.
4. **HIGH — `soft_feistel_int8` is documented "bijective hash — every key
   maps to a unique image" but has 49 collisions on the 256-key `Int8`
   domain.** `src/persistent/hashcons_feistel.jl:14-16, 67-72`. The test
   (`test_persistent_hashcons.jl:151-158`) knows it's not bijective but
   the source docstring still claims it is.
5. **HIGH — Integer overflow and div-by-zero are silent.** `typemin ÷ -1`
   returns `typemin` (wrapping overflow), `x ÷ 0` returns all-ones or
   all-negative-ones depending on dividend sign. Tests explicitly skip
   these (`test_division.jl:47`) — the behaviour is not specified anywhere.

---

## 1. Integer arithmetic

### 1.1 `typemin ÷ -1` silently overflows — HIGH

- **File:** `src/divider.jl`, used via `src/lower.jl:lower_divrem! (1422)`
- **Probe:**
  ```bash
  julia --project -e 'using Bennett; c = reversible_compile((a::Int8,b::Int8)->div(a,b), Int8, Int8); println(simulate(c, (Int8(-128), Int8(-1))))'
  # → -128
  ```
- **Why it matters:** Julia's native `÷` throws `DivisionError` for
  `typemin ÷ -1` (signed overflow is undefined). The circuit silently
  produces `-128`, matching x86 `idiv`'s documented wrap-around. No test
  covers this path (`test_division.jl:47` explicitly skips:
  `# Edge cases (skip typemin/-1 which is UB: overflow)`).
- **Reversibility is preserved** — ancillae still return to zero. But
  `simulate(c, (typemin, -1)) ≠ native`.
- **Fix:** Either document "x86 semantics: typemin/-1 wraps" in
  `divider.jl` header, add a test pinning the behaviour, or reject these
  inputs up-front.

### 1.2 `x ÷ 0` returns implementation-defined garbage — HIGH

- **File:** `src/divider.jl:8-20` (`soft_udiv`)
- **Probe:** see "Quick probes" appendix for full table.
- **Observed behaviour:** `x ÷ 0` returns `-1` for positive `x`, `+1` for
  negative `x`, `-1` for `0 ÷ 0`. This is a consequence of the
  `fits = r >= b` check: with `b = 0`, `fits` is always true, so the
  quotient fills with 1s, then the sign-fix flips it.
- **Why it matters:** Native `div(x, 0)` throws `DivisionError`. The
  circuit silently returns garbage. Downstream code that compiles
  `if b != 0; a÷b else 0 end` works, but `div(a, b)` does not. No test
  checks the no-guard case.
- **Fix:** Document. Add a test for each division by zero path.

### 1.3 `typemin * -1` silently overflows — MEDIUM

- **File:** `src/multiplier.jl:lower_mul!` (line 2)
- **Probe:** `simulate(c, Int8(-128)) → -128` for `f(x) = x * Int8(-1)`.
- Matches native Julia wrap semantics for `Int` (which in Julia also
  wraps — `Int8(-128) * Int8(-1) == -128`). Matches native, so low
  priority. Note that for `*` Julia does not throw — consistent.

### 1.4 Variable-shift amount exceeding width — LOW

- **File:** `src/lower.jl:lower_var_shl! (1224), lower_var_lshr! (1208),
  lower_var_ashr! (1240)`
- **Observed:** Julia's `<<` / `>>` lowering wraps a `select` around
  `shl`/`lshr` checking `shift >= 8` (see `code_llvm(<<, Tuple{Int8,Int8})`),
  so the circuit saw a branch-select and is correct. However, the barrel
  shifter itself (`lower_var_*`) computes `_shift_stages(W, b_len) =
  ceil(log2(W))` stages — if a bare `shl i8 %x, %c` (no Julia wrapper)
  were fed in with `c == 8`, the result would be undefined-but-
  deterministic: the bit-select MUX tree only sees bits 0..2 of the
  shift amount, so `shift=8` produces `shift=0` semantics (identity), not
  zero.
- **Risk:** Any future frontend that emits raw LLVM shifts without
  Julia's wrapper will quietly mis-shift. Assertion-worthy.

### 1.5 `_cond_negate_inplace!` leaks carry ancillae — NIT

- **File:** `src/lower.jl:1496-1513`
- Every iteration allocates a fresh `next_carry` and never frees the
  previous one. For `W=64`, 64 wires of slop per call. Called twice per
  `lower_divrem!` with signed ops → 128 wires of slop per
  signed div. Not a correctness bug (Bennett uncompute cleans them), but
  it explains part of the ~279 000-wire ancilla count on `sdiv` circuits.

---

## 2. Control flow

### 2.1 **CRITICAL** — `lower_loop!` drops body-block instructions

- **File:** `src/lower.jl:692-782`
- **Bug:** The unroll loop only iterates over `header.instructions` (line
  724: `body_insts = [inst for inst in header.instructions if !(inst
  isa IRPhi)]`). When Julia emits a loop whose body lives in its own
  basic block (any non-trivial body does, with `optimize=false`), those
  instructions are never lowered inside the unroll. When `lower_loop!`
  tries to resolve the latch phi's incoming operand (e.g. `%4 = add`
  defined in L7), it errors with `Undefined SSA variable: %__v7`.
- **Reproduction:**
  ```julia
  function indirect_loop(x::Int8, n::Int8)
    a = Int8(0); b = Int8(0); i = Int8(0)
    while i < n
      a = a + x
      b = b ⊻ a
      i = i + Int8(1)
    end
    return b
  end
  # optimize=false → UndefVarError
  reversible_compile(indirect_loop, Int8, Int8;
                     max_loop_iterations=5, optimize=false)
  #   ERROR: Undefined SSA variable: %__v7
  # optimize=true → vectoriser emits unsupported <8 x i8> vector phi
  reversible_compile(indirect_loop, Int8, Int8;
                     max_loop_iterations=5, optimize=true)
  #   ERROR: unsupported vector opcode LLVMPHI
  ```
- **Why existing tests don't catch it:**
  - `test_loop.jl` uses a constant `for i in 1:4` range → fully unrolled
    by LLVM before extract.
  - `test_loop_explicit.jl`'s `collatz_steps` has ALL ops in the header
    block `L8: preds = %L8, %top` (Julia unusually inlines the body into
    the header for single-successor loops).
- **Severity:** CRITICAL. This is the flagship feature (bounded-loop
  unrolling) and the actual unroll code path does not work for the
  canonical `while i < n; body; end` pattern on the CLAUDE.md-mandated
  `optimize=false` path.

### 2.2 `max_loop_iterations` is not actually bounding — HIGH

- **File:** `src/lower.jl:307, 692`
- **Observation:** Due to bug 2.1, every existing loop test that compiles
  passes because LLVM folded the loop. In those cases the gate count is
  identical for `K=3`, `K=10`, `K=30` on the same function — confirming
  that `max_loop_iterations` currently has no effect on the circuit.
- **Action required:** Fix 2.1 first, then add a regression test that
  verifies gate count scales with K on a non-foldable loop.

### 2.3 Switch with duplicate targets — MEDIUM

- **File:** `src/ir_extract.jl:_expand_switches (994-1082)`
- **Bug:** `phi_remap` is a `Dict{Symbol,Symbol}` keyed by target label
  (line 1045). When two switch cases branch to the same target block
  (legal in LLVM IR), later entries overwrite earlier ones — the phi at
  that target gets only the last rewriter. In LLVM IR a phi node has
  exactly one incoming entry per unique predecessor, so when the switch
  is expanded into N cascaded comparison blocks we now have N distinct
  predecessors, each contributing the same value. Current code picks
  one, silently.
- **Probe (suspected — no direct test):**
  ```julia
  f(x::Int8) = let r = Int8(0)
    r = (x == Int8(1)) ? Int8(10) :
        (x == Int8(2)) ? Int8(20) :
        (x == Int8(3)) ? Int8(10) :  # same target as case 1
        Int8(0)
    r
  end
  ```
  Julia compiles `x==1||x==3 ? 10 : …` into a switch with two cases
  sharing a target block (depending on optimisation).
- **Fix:** `phi_remap` needs a multi-value list and `_expand_switches`
  must emit one phi incoming per synthetic predecessor that reaches the
  target.

### 2.4 Switch with zero cases — LOW

- **File:** `src/ir_extract.jl:1006-1011`
- Degenerate case is handled: unconditional branch to default. Good.

### 2.5 Phi with a single predecessor — LOW

- **File:** `src/lower.jl:lower_phi!` (928)
- Not directly tested. `resolve_phi_predicated!` likely handles it but
  the `resolve_phi_muxes!` fallback at line 1012 has an explicit
  `length(incoming) == 1 && return incoming[1][1]` early-out. If the
  predicated path is taken with a single incoming, behaviour less clear.

### 2.6 Nested diamond CFG (4-deep) — GOOD

- **Probe passed:** 4-deep nested `if` chain with 16 distinct leaf
  constants compiles, runs correctly for all 16 input combinations,
  and `verify_reversibility` passes. The phi-resolution algorithm handles
  this case well despite the CLAUDE.md warning about diamond
  sensitisation. No regression found here.

---

## 3. Soft-float — NaN and subnormal edge cases

### 3.1 **CRITICAL** — NaN payload and sign are lost

- **Files:** `src/softfloat/fadd.jl:133`, `fmul.jl:203`, `fdiv.jl:95`,
  `fsqrt.jl`. Pattern: `result = ifelse(a_nan | b_nan, QNAN, result)`
  where `QNAN = UInt64(0x7FF8000000000000)`.
- **Probe:**
  ```julia
  nan = UInt64(0x7FF8000000000042)   # qNaN with payload 0x42
  soft_fadd(nan, reinterpret(UInt64, 1.0))
  # circuit = 0x7ff8000000000000  (payload erased)
  # native  = 0x7ff8000000000042  (payload preserved per IEEE 754-2008 §6.2.3)
  soft_fmul(reinterpret(UInt64, Inf), reinterpret(UInt64, 0.0))
  # circuit = 0x7ff8000000000000  (+qNaN)
  # native  = 0xfff8000000000000  (−qNaN — sign = sign_a XOR sign_b)
  ```
- **Violates:** IEEE 754-2008 §6.2.3 ("If two or more inputs are NaN,
  then the payload of the resulting NaN should be identical to the
  payload of one of the input NaNs if representable"). Also
  `CLAUDE.md §13` ("Every soft-float function must be bit-exact against
  Julia's native floating-point operations.").
- **sNaN quieting:** `soft_fmul(0x7FF4000000000000, _)` returns
  `0x7FF8000000000000` (canonical qNaN). Native returns
  `0x7FFC000000000000` (sNaN → qNaN quieting via bit 51 set). The
  circuit loses the sNaN payload entirely.
- **Tests masking the bug:** `test_softfmul.jl:11-12`:
  ```julia
  if isnan(expected)
      @test isnan(reinterpret(Float64, result_bits))
  ```
  — checks only `isnan`, not bit-exactness. Every soft-float test file
  has this pattern. Search: `grep -rn "isnan(expected)" test/test_softf*.jl`.
- **Fix:** On the NaN override, select a NaN payload from the inputs
  (prefer `a_nan` over `b_nan`, set bit 51 to quiet sNaN). One approach:
  ```julia
  chosen_nan = ifelse(a_nan, a, b) | UInt64(0x0008000000000000)
  result = ifelse(a_nan | b_nan, chosen_nan, result)
  ```
- **Severity:** CRITICAL for "bit-exact" claim; MEDIUM-HIGH for
  reversible-circuit use (payload is observable, so any downstream
  function comparing two NaN-producing circuits will get wrong answers).

### 3.2 `soft_fptosi` handles Inf/NaN as zero — MEDIUM

- **File:** `src/softfloat/fptosi.jl:15-57`
- **Probe:**
  ```
  soft_fptosi(Inf)  → 0
  soft_fptosi(-Inf) → 0
  soft_fptosi(NaN)  → 0
  soft_fptosi(1e19) → -8446744073709551616  (wrap, not saturate)
  ```
- The docstring claims "NaN/Inf → undefined (match hardware)". Actual
  x86 SSE `cvttsd2si` returns `0x8000000000000000` (INT_MIN) for all
  three; the circuit returns `0`. Not matching hardware. Not matching
  Julia (which throws `InexactError`).
- **Overflow:** x86 returns `INT_MIN` for any overflow; circuit wraps.
  Julia throws.
- **No test in `test_softfconv.jl` checks Inf/NaN/overflow boundaries.**

### 3.3 `fptoui` is routed through `soft_fptosi` — MEDIUM

- **File:** `src/ir_extract.jl:1594-1615`
  ```julia
  if opc in (LLVM.API.LLVMFPToSI, LLVM.API.LLVMFPToUI)
      …
      callee = _lookup_callee("soft_fptosi")
  ```
- `fptoui` is UNSIGNED float-to-int. `fptoui(1e19, UInt64)` should
  return `10000000000000000000` (fits in UInt64). Routing through
  `soft_fptosi` (which returns signed Int64) will sign-interpret the
  result — `1e19` becomes negative, truncated to UInt64 gives wrong
  bits.
- **No `soft_fptoui` exists in `src/softfloat/`.**

### 3.4 Soft-float `1.0 / 0.0` — OK

- **Probe:** `soft_fdiv(1.0, 0.0) = 0x7FF0000000000000 = +Inf` — matches
  native. `soft_fdiv(0.0, 0.0) = 0x7FF8000000000000 = +qNaN` — matches
  native magnitude. Signed-zero divide-by-zero: similar.

### 3.5 Subnormal × subnormal — OK

- **Probe:** `soft_fmul(nextfloat(0.0), nextfloat(0.0)) = 0` (flush to
  zero) — matches native.

### 3.6 Rounding modes

- **File:** all `_sf_round_and_pack` sites hard-code round-to-nearest-
  even (`softfloat_common.jl:137`). No support for RoundTowardZero,
  RoundDown, RoundUp. Not exposed anywhere, not configurable, not
  tested. If Julia emits a different rounding mode via intrinsics
  (`llvm.experimental.constrained.*`) the compiler silently gets it
  wrong.

### 3.7 `fpext` / `fptrunc` not implemented — MEDIUM

- **File:** `src/ir_extract.jl:308-309` (only in the opcode-name map,
  not dispatched). `reversible_compile(x -> Float64(x), Float32)` →
  `fpext in @…: unsupported LLVM opcode`. Same for `Float64 → Float32`.
- Fine — explicitly in the "missing opcodes" list in README — but this
  also means any Julia code that promotes Float32 to Float64 internally
  (e.g. `sin(x::Float32)` doing `Float32(sin(Float64(x)))`) will fail.

---

## 4. Type conversion edges

### 4.1 `sext i1 → i64` / `trunc i64 → i1` — OK

- **Probes passed.** `sext` fills with MSB correctly
  (`src/lower.jl:1402-1404`); `trunc` discards above `to_width`
  correctly (line 1405-1406).

### 4.2 Bool/Width-1 values — OK

- Handled as Int with width 1. Identity / MUX / phi all work.

### 4.3 Mixed-signedness equality — PROBABLY OK

- **Suspected:** `icmp eq i32 -1, UInt32(0xFFFFFFFF)` — bitwise equality
  holds. The lowering (`lower_eq!`) is bit-XOR based so this is correct.
  No dedicated test.

---

## 5. LLVM IR quirks

### 5.1 Empty / trivial function — NOT TESTED

- `reversible_compile(x -> x, Int8)` compiles to a 10-gate circuit
  (identity CNOTs + some bennett plumbing). Works. No empty-function
  test (e.g. a function with no instructions, just `ret` — though Julia
  probably synthesises at least one `add 0` or similar, depends on
  type inference).

### 5.2 Unnamed / post-SROA values — PROBABLY OK

- `src/ir_extract.jl` does two-pass name assignment. Would be a good
  fuzzing target; I did not drill down.

### 5.3 Dead code — UNBOUNDED WASTE (not correctness)

- **File:** `src/lower.jl:lower_block_insts!` — every SSA definition is
  lowered into gates regardless of whether its result is used. If LLVM
  leaves a dead `mul i64 %x, %y` in the IR (unusual but possible with
  `optimize=false`), the multiplier circuit is still emitted.
- Not a correctness issue. Reviews 1/6 probably cover this.

### 5.4 Constant `(1 << W) - 1` mask in `resolve!` — LOW

- **File:** `src/lower.jl:176`
  `val = op.value & ((1 << width) - 1)`
- For `width == 64`, `1 << 64 == 0` on Int64 (Julia saturates shift
  differently than C), so mask is `-1` = all-ones — works out. For
  `width == 63`, mask = `0x7FFFFFFFFFFFFFFF` — works. For
  `width > 64` (hypothetical — IR parser rejects this), would be undef.
  No assertion.

### 5.5 Huge / all-ones constant operands — OK

- Probes for `x + 2^62`, `x & 0`, `x | -1` all match native.

---

## 6. Persistent data structures

### 6.1 **HIGH** — `soft_feistel_int8` is NOT a bijection on Int8

- **Files:** `src/persistent/hashcons_feistel.jl:14-16, 67-72`
- **Docstring says:**
  - Line 15: "Feistel is a bijection on UInt32 → UInt32. No collisions."
  - Line 16-17: "Used as a pre-hash on persistent-map keys: every key
    maps to a unique image."
  - Line 67-72: "`soft_feistel_int8`: Zero-extends to UInt32, runs
    Feistel, returns the low byte …"
- **Reality:** zero-extending Int8 to UInt32 gives 256 distinct inputs,
  but truncating the UInt32 output to the low byte is NOT a bijection
  on that image. Measured: 256 inputs → 207 distinct outputs, with 37
  distinct collision classes (e.g. hash=-15 ← {-15, -7, -3}; hash=-16 ←
  {-16, -8, -4, -2, -1}). See probes appendix for full list.
- **Impact:** Any persistent-map impl that trusts the "no collisions"
  property is silently storing duplicate keys. The correctness of
  `hashcons_feistel.jl`-backed persistent maps under collision is not
  documented or tested.
- **Fix paths:**
  a. Restrict to UInt16 (Feistel is a true bijection on UInt32 but `<8` bits
     of image is not enough entropy).
  b. Use all 32 bits of image — store it in a wider slot.
  c. Fix the docstring to say "approximate hash with ~5% collision rate
     on Int8 domain" and change `perfect hash` → `low-collision hash`.
- `test_persistent_hashcons.jl:151-158` knows about this ("Not strictly
  bijective on Int8") but asserts only `length(images) > 200`, which is
  permissive. Stronger: measure and pin the exact collision count so
  any regression (e.g. rotation constants changed) is caught.

### 6.2 `linear_scan_pmap_get` returns 0 for absent keys — MEDIUM

- **File:** `src/persistent/linear_scan.jl:80`, 98:
  `return reinterpret(Int8, UInt8(acc & UInt64(0xff)))` with
  `acc = UInt64(0)` initially.
- Silent ambiguity: `get(map, absent_key) == 0` is indistinguishable
  from `get(map, stored_key_with_value_0)`.
- The docstring acknowledges `"or zero(Int8) if no slot matches"` —
  not a *bug* but a footgun. Dense test coverage in
  `test_persistent_hashcons.jl` does not exercise the absent-key case.

### 6.3 Map overflow beyond `max_n` — LOW

- **File:** `src/persistent/linear_scan.jl:50-51`
  ```julia
  target = ifelse(count >= max_n, max_n - 1, count)
  new_count = ifelse(count >= max_n, max_n, count + 1)
  ```
- Overflow writes over the LAST slot repeatedly. Documented
  ("impl-defined per protocol"). OK.

### 6.4 Hash collisions in `hashcons_feistel.jl` / `hashcons_jenkins.jl` — NOT FULLY PROBED

- See 6.1 for Feistel. Jenkins not separately probed.

---

## 7. Wire allocator / ancilla

### 7.1 `WireAllocator` with 0-sized allocation — LOW

- **File:** `src/wire_allocator.jl:8`
- `allocate!(wa, 0)` returns `Int[]`. Fine.

### 7.2 `free!` double-free — NOT CHECKED

- `free!` does not check if the wire is already on the free list. A
  double-free would cause the wire to appear twice in `free_list` and
  later get handed to two different SSA names. Fail-fast needed.
  No test exercises `free!` directly in the current code — it's used
  only by the pebbling / eager cleanup passes.

### 7.3 Bennett construction — un-paired forward/uncompute — UNLIKELY

- `src/bennett_transform.jl:44-46` — the `for i in length(lr.gates):-1:1`
  iterates exactly `length(lr.gates)` times, so forward + uncompute are
  always paired. OK.

### 7.4 `bennett` on empty gate list — NOT CHECKED

- If `lr.gates` is empty, `copy_wires` still allocated (1+n_out), and
  the forward + reverse is empty. Likely fine.

---

## 8. Default `optimize=true` vs CLAUDE.md §5

- **File:** `src/Bennett.jl:59`, `src/Bennett.jl:269`
  ```julia
  function reversible_compile(f, arg_types::Type...;
                              optimize::Bool=true, …)
  ```
- `CLAUDE.md §5` says:
  > "Always use `optimize=false` for predictable IR when testing."
- Default contradicts the project's own guidance. The loop bug (§2.1)
  is actively hidden by this default — end users running with defaults
  do not see `lower_loop!` fail because LLVM pre-unrolls or converts to
  `select`. The bug will bite the first user whose loop cannot be
  folded.
- **Fix:** Either change default to `false` and document why, or add
  a test fixture that runs EVERY test with `optimize=false` and
  compares.

---

## 9. Other notable edge cases

### 9.1 Integer-div-by-zero during sdiv — reversibility still holds

- **Probe:** `verify_reversibility(c)` passes even when `simulate` is
  called with divisor 0. Bennett uncompute is robust. The "wrong"
  output value is deterministic.

### 9.2 Controlled-circuit correctness — OK

- Tested `controlled(reversible_compile(x->x, Int8))`: ctrl=false → 0,
  ctrl=true → x. All values pass.

### 9.3 No tests for `soft_fptoui` (the unsigned variant) — HIGH

- Already noted under 3.3. There is no `fptoui` test fixture either.

### 9.4 `freeze` → identity — OK

- `src/ir_extract.jl:1590` lowers LLVM `freeze` to `add 0`. Correct
  semantically since the circuit is deterministic (no poison).

---

## Quick probes — exact commands

All runnable against the current tree:

```bash
# 1. Loop body dropped (CRITICAL)
julia --project -e '
using Bennett
f(x::Int8, n::Int8) = let a=Int8(0), b=Int8(0), i=Int8(0)
  while i < n; a = a + x; b = b ⊻ a; i = i + Int8(1); end
  b
end
reversible_compile(f, Int8, Int8; max_loop_iterations=5, optimize=false)
# ERROR: Undefined SSA variable: %__v7
'

# 2. NaN payload lost
julia --project -e '
using Bennett
nan = UInt64(0x7FF8000000000042)
println(string(soft_fadd(nan, reinterpret(UInt64, 1.0)), base=16))  # 7ff8000000000000
println(string(reinterpret(UInt64, reinterpret(Float64,nan)+1.0), base=16))  # 7ff8000000000042
'

# 3. Feistel not bijective on Int8
julia --project -e '
using Bennett
images = Set{Int8}()
for k in Int8(-128):Int8(127); push!(images, soft_feistel_int8(k)); end
println("distinct images: ", length(images), " of 256")  # 207
'

# 4. max_loop_iterations ignored (because loop body dropped)
julia --project -e '
using Bennett
f(x::Int8, n::Int8) = let r=Int8(0), i=Int8(0)
  while i < n; r = r + x; i = i + Int8(1); end; r
end
for K in (3, 10, 30)
  c = reversible_compile(f, Int8, Int8; max_loop_iterations=K)
  println("K=$K: ", gate_count(c))  # identical for all K
end
'

# 5. typemin/-1 silent overflow
julia --project -e '
using Bennett
c = reversible_compile((a::Int8,b::Int8)->div(a,b), Int8, Int8)
println(simulate(c, (Int8(-128), Int8(-1))))  # -128
# native throws DivisionError
'

# 6. Inf × 0 sign mismatch
julia --project -e '
using Bennett
r = soft_fmul(reinterpret(UInt64,Inf), reinterpret(UInt64,0.0))
println(string(r, base=16))  # 7ff8000000000000 (+qNaN)
println(string(reinterpret(UInt64, Inf*0.0), base=16))  # fff8000000000000 (-qNaN)
'

# 7. div-by-zero garbage
julia --project -e '
using Bennett
c = reversible_compile((a::Int8,b::Int8)->div(a,b), Int8, Int8)
for (a,b) in [(Int8(5),Int8(0)),(Int8(-5),Int8(0)),(Int8(0),Int8(0))]
  println("div($a,$b) = ", simulate(c,(a,b)))
end
# 5÷0 = -1, -5÷0 = 1, 0÷0 = -1  (all would throw natively)
'
```

---

## Priority summary

| # | Finding | Priority | File |
|---|---------|----------|------|
| 2.1 | `lower_loop!` drops body-block insts | **CRITICAL** | `src/lower.jl:692-782` |
| 3.1 | Soft-float loses NaN payload + sign | **CRITICAL** | `src/softfloat/{fadd,fmul,fdiv,fsqrt}.jl` |
| 2.2 | `max_loop_iterations` effectively ignored | HIGH (bc 2.1) | same |
| 6.1 | `soft_feistel_int8` not bijective (docstring lies) | HIGH | `src/persistent/hashcons_feistel.jl:14-16` |
| 8 | Default `optimize=true` vs CLAUDE.md §5 | HIGH | `src/Bennett.jl:59,269` |
| 1.1 | `typemin ÷ -1` silent wrap | HIGH | `src/divider.jl` |
| 1.2 | `x ÷ 0` silent garbage | HIGH | `src/divider.jl` |
| 3.3 | `fptoui` routed through signed conv | MEDIUM | `src/ir_extract.jl:1594-1615` |
| 3.2 | `soft_fptosi(Inf/NaN) → 0` | MEDIUM | `src/softfloat/fptosi.jl` |
| 2.3 | Switch with duplicate targets | MEDIUM | `src/ir_extract.jl:994-1082` |
| 3.6 | No rounding-mode support | MEDIUM | `src/softfloat/softfloat_common.jl` |
| 6.2 | `pmap_get` absent-key collides with stored-zero | MEDIUM | `src/persistent/linear_scan.jl` |
| 1.5 | `_cond_negate_inplace!` leaks carry ancillae | NIT | `src/lower.jl:1496` |
| 1.3 | `typemin * -1` silent wrap (matches native) | LOW | — |
| 1.4 | Raw bare `shl` > W behaviour | LOW | `src/lower.jl:1224` |
| 5.1 | No empty-function test | LOW | — |
| 5.4 | `(1<<64)-1` mask relies on Julia wrap | LOW | `src/lower.jl:176` |
| 7.1-7.4 | Wire allocator edge cases | LOW | `src/wire_allocator.jl` |

---

## Recommendation for immediate action

1. **Fix `lower_loop!`** to process ALL blocks between header and exit
   for each unroll iteration (topological order within the loop body,
   re-resolve phi each iter). This is the single most load-bearing bug
   — it invalidates the "bounded loops" feature claim.
2. **Default `optimize=false`** or add a CI matrix that runs the full
   test suite under both. Current state: tests pass with `optimize=true`
   because LLVM hides the bugs. `optimize=false` reveals them.
3. **Fix NaN propagation** in all four soft-float ops. Pattern:
   select a NaN input (prefer a) and force bit 51 to quiet it.
4. **Update `hashcons_feistel.jl` docstring** to not claim bijection on
   truncated outputs; add a pinned collision-count test.
5. **Document** `div`/`rem` edge-case semantics (typemin/-1, /0) and
   add explicit tests that pin the behaviour.
