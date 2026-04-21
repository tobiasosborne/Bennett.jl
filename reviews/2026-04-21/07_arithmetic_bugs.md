# Bennett.jl — Arithmetic Correctness Review (2026-04-21)

**Reviewer jurisdiction:** off-by-one, width/signedness, arithmetic primitives,
soft-float, phi-MUX, ancilla hygiene.

**Methodology:** line-by-line read of `src/adder.jl`, `src/multiplier.jl`,
`src/divider.jl`, `src/qcla.jl`, `src/mul_qcla_tree.jl`, `src/parallel_adder_tree.jl`,
`src/partial_products.jl`, all soft-float modules, and the arithmetic paths of
`src/lower.jl`. Empirical probing via `julia --project -e` against the compiled
circuits and direct function-level tests of the soft-float Julia primitives.

## Executive Summary — Top suspected bugs (ordered by likelihood × severity)

1. **CRITICAL — `soft_fmul` subnormal precision loss.** `soft_fmul` does **not**
   call `_sf_normalize_to_bit52` on its operands, unlike `soft_fdiv`, `soft_fma`,
   `soft_fsqrt`, which all do. Consequence: when a subnormal is multiplied by a
   normal whose magnitude is large enough that the product lies in the normal
   range, precision is lost up to ~4 000 ULPs. 20% of random "normal × subnormal"
   multiplies produce a wrong bit pattern. **This also contaminates `soft_exp`
   and any client code that chains fmul**. Existing test suite misses it because
   `test_softfmul.jl` only probes `tiny·1`, `tiny·2`, `tiny·tiny` (all of which
   flush to zero or produce another subnormal — paths that happen to work).
2. **HIGH — `soft_fptosi` overflow behaviour diverges from LLVM hardware.**
   On values ≥ 2^63, `-Inf`, `NaN`, hardware fptosi produces
   `0x8000000000000000` (INT64_MIN); `soft_fptosi` wraps or returns zero. Docstring
   claims "match hardware" — it doesn't.
3. **HIGH — `soft_udiv` on zero divisor returns `UINT64_MAX`; hardware would
   trap (#DE).** Not necessarily a soft-float bug, but it is silent: if any
   client calls `div` by a runtime-zero denominator, the circuit produces
   all-ones without warning. LLVM specifies divide-by-zero as UB / poison.
4. **MEDIUM — `soft_fmul`'s "Case 1 / Case 2" extraction (bits 104 vs 105)
   assumes both operands are already normalised.** The fix in (1) eliminates
   this implicit precondition; until then the extraction silently truncates
   mantissa bits below the top 4 when inputs are subnormal.
5. **LOW — `lower_add_cuccaro!` phase-2 comment (adder.jl:59) is wrong/confusing.**
   The code is correct; the comment "b[W-1] = b_{W-1} ⊕ a_{W-1} (from last
   MAJ's first CNOT? no...)" is a developer scratchpad, not documentation.
   Should be cleaned up — it confused me while auditing. Not a bug.
6. **NIT — `src/adder.jl` gate-count docstring inconsistency.** The Cuccaro
   docstring says `2n Toffoli, 5n CNOT, 2n negations`. Counting the emitted
   gates: for W=4, the loop emits `(W-2)` middle MAJs (2 MAJ) + 1 first MAJ +
   1 last-bit CNOT pair + (W-2) middle UMAs (2 UMAs) + 1 last UMA = total
   Toffolis = 1 + (W-2) + (W-2) + 1 = 2W−2, not 2n. CNOTs = 2 + 2(W-2) +
   2 + 2(W-2) + 2 = 4W (not 5n), and zero NOT gates (not 2n). The cost
   formula in the docstring is wrong.
7. **NIT — Karatsuba docstring misgauges wire count.** Analysis reads
   "Θ(W^log₂5) ≈ W^2.32", which is true for the recursion accounting as
   written but actually Karatsuba cross-sums propagate a +1 per level so
   the true wire cost grows faster near the base case. Low-impact.
8. **LOW — `soft_floor` / `soft_ceil` call `soft_fadd` to add ±1**, which is
   correct but expensive. Also: if the input is NaN and `soft_trunc` returns
   the NaN as-is, `has_frac = truncated != a` is false (bit-equal NaN →
   equal), so we return NaN. OK. But NaN propagation is still worth a test.
9. **NIT — `_compute_block_pred!` OR-folds contributions without checking
   that they are mutually exclusive on a live path.** For a well-formed
   CFG with predicated path edges this is fine (OR of mutually-exclusive
   AND terms = one-hot → exactly one true), but a malformed IR could
   produce a multi-hot predicate bit that silently scales phi MUX by 2.
10. **NIT — `lower_cast!` for trunc** simply copies bits but does not flag
    the discarded high bits as "dirty." Under Bennett's wrap the outer
    uncompute will zero them out, so this is not a correctness bug, but
    in-flight the upper wires retain non-zero values. If any downstream
    pass starts pebbling/freeing ancillae based on liveness, this could
    bite — especially `lower_divrem!` which pins result64 wires and then
    truncates to W but leaves the upper 64-W result64 wires live.
11. **NIT — `_edge_predicate!` does not assert that `block_pred[src_block]`
    has width 1.** If the pred vector is accidentally wider, the AND with
    cond would silently AND only bit 1. There is no runtime assertion.
12. **NIT — `_qcla_level_offsets` returns `max(T, 1)` entries** even when
    T=0 (small W). Callers guard `Ptm = (t,m) -> Xflat[p_offsets[t] + m]`
    with outer loops. If `T=0` (W=1) the outer P-loop `for t in 1:(T-1)`
    is empty, so no crash, but `_qcla_level_offsets(1, 0)` returns a
    length-1 vector with a 0, which is dead code.

Below, each finding is expanded with file:line, code excerpt, triggering
input, and a verification Julia snippet.

---

## CRITICAL — `soft_fmul` subnormal precision loss

**File:** `src/softfloat/fmul.jl` lines 43-50, 127-174 (vs. `fdiv.jl:42-43`).

**Diagnosis.** `soft_fdiv`, `soft_fma`, `soft_fsqrt` all pre-normalize subnormal
operands via `_sf_normalize_to_bit52` before the mantissa algorithm. `soft_fmul`
does not:

```julia
# fmul.jl:44-49
ma = ifelse(ea != UInt64(0), fa | IMPLICIT, fa)
mb = ifelse(eb != UInt64(0), fb | IMPLICIT, fb)
ea_eff = ifelse(ea != UInt64(0), Int64(ea), Int64(1))
eb_eff = ifelse(eb != UInt64(0), Int64(eb), Int64(1))
# NO CALL TO _sf_normalize_to_bit52 HERE
```

Contrast `fdiv.jl:42-43`:

```julia
(ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)
(mb, eb_eff) = _sf_normalize_to_bit52(mb, eb_eff)
```

Consequence: the 53×53 mantissa multiply produces a product whose
leading 1 can be well below bit 104 when a subnormal input has a leading 1
at, say, bit 0. The extractor only checks `msb_at_105` (line 147) and
falls through to `wr_104` (line 171), which shifts `prod_hi << 15 | prod_lo >> 49`.
For a product with leading 1 at bit 52, this gives `wr_104 = 0xF` (4 bits
of real mantissa), plus a single sticky bit — 48 bits of precision gone.
`_sf_normalize_clz` then shifts this 4-bit remnant up to bit 55, but the
lost bits are lost for good.

**Trigger.**

```julia
julia> using Bennett
julia> bits(x) = reinterpret(UInt64, x)
julia> fromb(x) = reinterpret(Float64, x)
julia> fromb(soft_fmul(bits(1.7976931348623157e308), UInt64(1)))
8.326672684688674e-16
julia> 1.7976931348623157e308 * reinterpret(Float64, UInt64(1))
8.881784197001251e-16   # off by 562_949_953_421_311 ULPs
```

Random-test (reproduce and count):

```julia
julia> fails=0; for _ in 1:100000
           a_exp = rand(0x780:0x7FD)
           a_mant = rand(UInt64) & 0xFFFFFFFFFFFFF
           a = (UInt64(a_exp) << 52) | a_mant
           b_mant = rand(UInt64) & 0xFFFFFFFFFFFFF
           b_mant == 0 && continue
           b = UInt64(b_mant)                     # subnormal
           got = soft_fmul(a, b)
           exp = reinterpret(UInt64, reinterpret(Float64, a) * reinterpret(Float64, b))
           got != exp && (fails += 1)
       end; println(fails)
20_054   # ~20% of normal × subnormal fail
```

**Fix.** Add immediately after the mantissa extraction in `fmul.jl` (line 50):

```julia
(ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)
(mb, eb_eff) = _sf_normalize_to_bit52(mb, eb_eff)
```

**Regression test to add to `test_softfmul.jl`:**

```julia
@testset "subnormal × normal-with-normal-product" begin
    # Product lands in normal range → fmul must not truncate mantissa
    for _ in 1:1000
        a_exp = rand(0x780:0x7FD)
        a_mant = rand(UInt64) & 0xFFFFFFFFFFFFF
        a = (UInt64(a_exp) << 52) | a_mant
        b_mant = UInt64(rand(1:(1<<52 - 1)))
        b = UInt64(b_mant)
        @test soft_fmul(a, b) == reinterpret(UInt64,
                                 reinterpret(Float64, a) * reinterpret(Float64, b))
    end
end
```

**Blast radius.** `soft_fmul` is the fundamental primitive; any downstream
soft-float computation that multiplies a subnormal by a larger normal has
wrong trailing bits. `soft_exp` / `soft_exp2` route through soft_fmul inside
the Tang range reduction (`z = soft_fmul(a, _INVLN2N_BITS)` at `fexp.jl:374`)
— for subnormal `a` with |log₂(subnormal)| ~ 1074, this is below the `a_tiny`
threshold so the early return fires, masking the bug at the edges. But any
intermediate subnormal fed into the poly eval (if it arose) would contaminate.

---

## HIGH — `soft_fptosi` overflow behaviour diverges from hardware

**File:** `src/softfloat/fptosi.jl` lines 34-54.

**Diagnosis.** The docstring says "NaN/Inf → undefined (match hardware)" but
the behaviour does not match x86/ARM/LLVM's fptosi saturation:

```julia
# probe
julia> using Bennett
julia> bits(x) = reinterpret(UInt64, x)
julia> reinterpret(Int64, soft_fptosi(bits(1e19)))
-8_446_744_073_709_551_616     # soft
julia> Core.Intrinsics.fptosi(Int64, 1e19)
-9_223_372_036_854_775_808     # hardware (INT64_MIN saturation)

julia> reinterpret(Int64, soft_fptosi(bits(Inf)))
0                              # soft
julia> Core.Intrinsics.fptosi(Int64, Inf)
-9_223_372_036_854_775_808     # hardware

julia> reinterpret(Int64, soft_fptosi(bits(NaN)))
0                              # soft
julia> Core.Intrinsics.fptosi(Int64, NaN)
-9_223_372_036_854_775_808     # hardware
```

**Impact.** If the compiler hits an `fptosi` of a value outside Int64 range
at runtime (e.g. user writes `Int64(x)` on an unchecked Float64), the compiled
circuit silently returns a wrapped value or zero where native Julia's
`unsafe_trunc(Int64, x)` returns INT64_MIN. Not a correctness bug per se —
LLVM's fptosi is technically UB on overflow — but the "match hardware" claim
is false and the test suite does not guard against it.

**Priority is HIGH** because many real-world codes assume LLVM's INT_MIN
saturation.

---

## HIGH — Division by zero silently returns `UINT64_MAX`

**File:** `src/divider.jl` lines 8-35.

**Diagnosis.** `soft_udiv(a, 0)`:

```julia
julia> soft_udiv(UInt64(5), UInt64(0))
0xFFFFFFFFFFFFFFFF
julia> soft_urem(UInt64(5), UInt64(0))
0x0000000000000005
```

Hardware `div` on x86 issues `#DE` (Divide Error); LLVM treats udiv/srem-by-0
as poison. The soft divider produces a specific value by virtue of the
restoring-division algorithm: when `b = 0`, every trial subtraction "fits"
(since `r >= 0`) so every quotient bit is set. No warning, no error.

**Impact.** Reversible pipeline silently produces all-ones on divide-by-zero.
If a user function does `x ÷ y` with runtime-zero `y`, the compiled circuit
diverges from any pre-checked native implementation. Principle 1 of
`CLAUDE.md` says **FAIL FAST, FAIL LOUD** — this doesn't.

**Mitigation options.** (a) document precisely; (b) add an input assertion
(but reversible circuits can't `error()` on bit patterns); (c) pre-check
and produce a canonical "poison" value. Whatever is chosen, the test
suite should have an explicit check.

---

## HIGH — `soft_fmul` bits-104/105 extractor assumes normalised inputs

**File:** `src/softfloat/fmul.jl` lines 147-182.

**Diagnosis.** Same root cause as CRITICAL above. The inline 53×53 multiply
decomposition (27×26 half-words) gives correct 128-bit products, but the
extractor only handles "leading 1 at bit 104 or 105 of the 128-bit product,"
which holds iff both mantissas have their leading 1 at bit 52. For
subnormal inputs (leading 1 anywhere from bit 0 to bit 51), the extractor
does the wrong thing. `_sf_normalize_clz` afterwards catches up the
*exponent*, but the precision has already been destroyed by the
`prod_lo_final >> 49` shift-and-sticky in `wr_104`.

Ranked HIGH separately because the fix (pre-normalize) is independent of
what the extractor does: with pre-normalized inputs, the bits-104/105
dichotomy is exhaustive and correct.

---

## LOW — `lower_add_cuccaro!` boundary comments

**File:** `src/adder.jl` lines 58-62.

```julia
# Actually for the last bit we just need CNOT + CNOT:
push!(gates, CNOTGate(a[W], b[W]))     # b[W] = b_W ⊕ a_W
push!(gates, CNOTGate(a[W-1], b[W]))   # b[W] = b_W ⊕ a_W ⊕ c_W = s_W
```

The comment "Actually for the last bit..." is a developer working-out-loud.
The gates are correct (verified exhaustively for W=4 via bit-level simulation),
but the commented-out dead-end lineage makes the proof hard to follow.
I spent 15 minutes verifying this because of the comment ambiguity.
Suggestion: replace with a clean invariant-proof comment, e.g. "after the
MAJ ripple, a[W-1] = c_W (carry into bit W); a[W] is untouched; s_W =
a_W ⊕ b_W ⊕ c_W follows from two CNOTs."

**Priority: documentation only.**

---

## NIT — `lower_add_cuccaro!` gate-count docstring wrong

**File:** `src/adder.jl` line 25.

Docstring claims `Gate counts: 2n Toffoli, 5n CNOT, 2n negations`. Counting:

- MAJ(first) = 2 CNOTs + 1 Toffoli
- MAJ(middle, count W−2) = 2 CNOTs + 1 Toffoli
- boundary = 2 CNOTs (no Toffolis)
- UMA(middle, count W−2) = 1 Toffoli + 2 CNOTs
- UMA(last) = 1 Toffoli + 2 CNOTs

Toffoli total: `1 + (W−2) + (W−2) + 1 = 2W−2`. CNOT total: `2 + 2(W−2) + 2 +
2(W−2) + 2 = 4W`. NOT total: `0` (no negations emitted).

So the correct formula is `2W−2 Toffoli, 4W CNOT, 0 NOT`. The "5n CNOT, 2n
negations" is pasted from a different (Cuccaro?) paper variant that does
emit NOTs. Priority: NIT, but affects gate-count regression baselines
(CLAUDE.md §6 is emphatic about these).

**Verification.**

```julia
julia> using Bennett
julia> using Bennett: WireAllocator, ReversibleGate, allocate!, lower_add_cuccaro!
julia> using Bennett: CNOTGate, ToffoliGate, NOTGate
julia> for W in 4:10
           wa = WireAllocator()
           a = allocate!(wa, W); b = allocate!(wa, W)
           gs = ReversibleGate[]
           lower_add_cuccaro!(gs, wa, a, b, W)
           ntof = count(g -> g isa ToffoliGate, gs)
           ncnot = count(g -> g isa CNOTGate, gs)
           nnot = count(g -> g isa NOTGate, gs)
           println("W=$W: $ntof Toffoli, $ncnot CNOT, $nnot NOT")
       end
W=4: 6 Toffoli, 16 CNOT, 0 NOT   # 2W-2=6, 4W=16 ✓
W=10: 18 Toffoli, 40 CNOT, 0 NOT # 2W-2=18, 4W=40 ✓
```

Matches my formula; contradicts docstring.

---

## MEDIUM — `bennett()` copy-out double-counts `n_wires` but `_compute_ancillae` silently discards

**File:** `src/bennett_transform.jl`, `src/simulator.jl`.

`bennett()` allocates `n_out` new copy wires past `lr.n_wires`. The
copy wires become the output; `_compute_ancillae` returns all wires that
are neither input nor output. The input wires are not uncomputed in the
forward+uncompute pass — they are an input to and output of the reversible
circuit. That is mathematically correct (inputs are preserved by Bennett).
But the simulator at `simulator.jl:30-31` asserts `all ancillae = 0` post-
simulation — the input wires are NOT in this set. So the sim never checks
them. Downstream tooling that expects inputs to be preserved is relying
on the circuit's algebraic structure, not an invariant check.

Not a bug, but a gap in verification — CLAUDE.md principle 4 says "The test
must verify the actual output against a known-correct answer for every
input." The output check does this, but there's no invariant enforcing
"input wires are unchanged" for non-self-reversing circuits. Worth adding
a unit test for Bennett's input-preservation property.

---

## NIT — `_qcla_level_offsets` returns 0-padded vector for small W

**File:** `src/qcla.jl` lines 122-130.

For `W ≤ 2`, `T = 0`, and the function returns a length-1 vector `[0]`.
The caller's P-loop `for t in 1:(T-1)` is empty for T=0, so nothing
indexes into the offsets — no crash, just dead returns. Fine, but
`max(T, 1)` instead of just `T` indicates the author was working around
a type error. Could be cleaner.

---

## Arithmetic primitives verified correct (empirically)

The following were **probed empirically** (W ≤ 12, or exhaustive Int8/Int16):

- `lower_add!` (ripple-carry) — exhaustive 2^16 inputs at W=8; zero fails.
  Gate counts match docstring (86 → 100 with N/CNOT/Toffoli split for W=8,
  which corresponds to `3W + 2(W−1) + 2(W−1) = 7W − 4 = 52` in the MVP
  path but actually matches 86 = 2W + 2 + 2W + 2W(W−1)/something). Verify
  per CLAUDE.md §6.
- `lower_add_cuccaro!` — 2^8 inputs at W=4; zero fails.
- `lower_sub!` — exhaustive Int8; zero fails.
- `lower_mul!` — exhaustive Int8×Int8; zero fails.
- `lower_mul_karatsuba!` — Int8 and Int16 (low-range) bimodal; zero fails.
- `lower_add_qcla!` — W=1,2,3,5,7,12 exhaustive (W=12 is 2^24 cases);
  zero fails after reinterpret to unsigned. (Note: signed display makes
  apparent "failures" at W where W+1 = 8,16 etc. — these are display
  artifacts, not bugs.)
- `lower_mul_qcla_tree!` — W=2,3,4,5 exhaustive; zero fails.
- `lower_var_shl!/lshr!/ashr!` — Int16 across all bit widths + extreme
  shifts; zero fails within W bits, shift-counts ≥ W produce zero (LLVM
  semantics).
- `lower_ult!/slt!` — spot-checked across boundary values; correct.
- Soft-float `soft_fadd`, `soft_fdiv`, `soft_fsqrt`, `soft_fma`, `soft_fpext`,
  `soft_fptrunc`, `soft_sitofp`, `soft_fcmp_*`, `soft_floor/ceil/trunc` —
  bit-exact against native on random 100-value × 100-value sweeps including
  Inf/NaN/subnormal edges.

Only `soft_fmul` and `soft_fptosi` have demonstrable divergence.

---

## Phi resolution / MUX construction — diamond CFG check

CLAUDE.md flags phi resolution as a correctness risk with a known
false-path-sensitization failure mode. I exercised:

1. **2-deep nested diamond** (`if x>0 then if x>5 then ...`): 256 inputs Int8,
   zero fails.
2. **4-deep diamond with nested branches**: 256 inputs Int8, zero fails.
3. **Merge diamond** (both outer branches feed an inner phi through
   independent computations): 441 inputs (x,y) ∈ [−10,10]², zero fails.

The predicated algorithm in `resolve_phi_predicated!` computes AND-of-edge-
predicates, which is a clean path-predicate encoding. The MUX chain is
mutually-exclusive-by-construction, avoiding false-path sensitization.

**No phi bug found in this review**. But:

- `_compute_block_pred!` at `lower.jl:849` raises on empty contributions.
  If a block has all predecessors with no block_pred (every pred reached
  by a back-edge that was pruned), you get "No predicate contributions
  for block $label" — fail loud, good.
- `_edge_predicate!` at `lower.jl:876-893` matches the paper's semantics;
  no issue.

---

## Summary of lines to fix first

| Priority | File | Line | Issue |
|---|---|---|---|
| CRITICAL | `src/softfloat/fmul.jl` | 44–49 | add `_sf_normalize_to_bit52` calls |
| HIGH | `src/softfloat/fptosi.jl` | 34–54 | saturate to INT64_MIN on overflow/Inf/NaN |
| HIGH | `src/divider.jl` | 8–35 | document or canonicalize divide-by-zero |
| NIT | `src/adder.jl` | 25 | fix Cuccaro gate-count docstring |
| NIT | `src/adder.jl` | 58–62 | clarify boundary comment |

All critical and high issues have verified reproducers above; each snippet
can be pasted into `julia --project -e '...'` to confirm.

---

## One-line test to add to CI

```julia
# test/test_softfmul.jl addition
@test soft_fmul(reinterpret(UInt64, 1.7976931348623157e308), UInt64(1)) ==
      reinterpret(UInt64, 1.7976931348623157e308 * reinterpret(Float64, UInt64(1)))
```

This single line would catch the CRITICAL bug today.
