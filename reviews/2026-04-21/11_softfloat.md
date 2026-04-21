# Soft-Float IEEE 754 Conformance Review — 2026-04-21

Reviewer: independent floating-point / numerical-analysis auditor
Scope: `src/softfloat/**` — IEEE 754 binary64 soft-float implementation
Method: source read, followed by empirical bit-exactness comparison against
Julia's `Base` floating-point operations on millions of random UInt64
patterns and hand-picked edge cases.

Hardware reference: `reinterpret(UInt64, af op bf)` where `af`, `bf =
reinterpret(Float64, a_bits, b_bits)`. This is x86-64 LLVM codegen with
Julia's standard semantics (round-to-nearest-ties-to-even, x87-style
indefinite NaN sign, qNaN payload propagation through arithmetic).

**BLUF: The library is good but not bit-exact. Three classes of bugs:
(1) a HIGH-severity `soft_fmul` subnormal-input precision loss bug
affecting ~11% of subnormal inputs (1–2 ULP), (2) systematic NaN-sign
and NaN-payload divergences across all arithmetic ops, (3) sNaN
quieting not performed on conversions. The CLAUDE.md §13 claim "every
soft-float function must be bit-exact against Julia's native
floating-point operations" is demonstrably false.**

---

## 1. Conformance matrix

Methodology key:
- **✓** = bit-exact vs Julia `Base` across spot-checked edge cases and
  random sampling (see §2 for details of each op's test run).
- **✗** = structural mismatch (bit-different, both finite or both NaN
  with different sign/payload that hardware would emit).
- **nan-sign** = produces canonical `QNAN=0x7FF8000000000000` where
  hardware would emit `0xFFF8000000000000` (same NaN, opposite sign bit).
- **nan-payload** = loses input NaN payload; canonicalizes to `QNAN`.
- **n/a** = edge case not applicable to op.
- **UNTESTED** = no explicit test in repo.

| Op | +0 / −0 | ±Inf | qNaN payload | sNaN quiet | subnorm input | subnorm output | overflow | underflow | RTNE | random bit-exact (N tested) |
|---|---|---|---|---|---|---|---|---|---|---|
| `soft_fneg` (fneg.jl) | ✓ | ✓ | ✓ | passes sNaN unchanged (matches Julia) | n/a | n/a | n/a | n/a | n/a | n/a |
| `soft_fadd` (fadd.jl) | ✓ | **nan-sign** (Inf−Inf) | **nan-payload** | **doesn't quiet** | ✓ | ✓ | ✓ | ✓ | ✓ | 200k ✓ modulo NaN |
| `soft_fsub` (fsub.jl) | ✓ | **nan-sign** | **nan-payload** | **doesn't quiet** | ✓ | ✓ | ✓ | ✓ | ✓ | 200k ✓ modulo NaN |
| `soft_fmul` (fmul.jl) | ✓ | **nan-sign** (Inf·0) | **nan-payload** | **doesn't quiet** | **✗ ~11% fail** | ✓ | ✓ | ✓ | ✓ | **200k — 23 structural** |
| `soft_fdiv` (fdiv.jl) | ✓ | **nan-sign** (Inf/Inf, 0/0) | **nan-payload** | **doesn't quiet** | ✓ | ✓ | ✓ | ✓ | ✓ | 500k ✓ modulo NaN |
| `soft_fma` (fma.jl) | ✓ | **nan-sign** | **nan-payload** | **doesn't quiet** | ✓ | ✓ | ✓ | ✓ | ✓ (single-rounded) | 300k ✓ modulo NaN |
| `soft_fsqrt` (fsqrt.jl) | ✓ | ✓ (+Inf→+Inf) | **nan-payload** (preserves but any NaN→QNAN) | **doesn't quiet** | ✓ | n/a (no subnorm sqrt) | n/a | n/a | ✓ (Kahan no-midpoint) | 500k positive ✓ |
| `soft_fcmp_oeq` | ✓ (+0=−0) | ✓ | n/a | ✓ | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_fcmp_olt` | ✓ | ✓ | n/a | ✓ | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_fcmp_ole` | ✓ | ✓ | n/a | ✓ | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_fcmp_une` | ✓ | ✓ | n/a | ✓ | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_fpext` F32→F64 | ✓ | ✓ | ✓ | **doesn't quiet (~50% of F32 NaN inputs)** | ✓ | n/a | n/a | n/a | always exact | 100k ✓ modulo NaN |
| `soft_fptrunc` F64→F32 | ✓ | ✓ | ✓ | ✓ (quiets correctly) | ✓ | ✓ | ✓ (overflow→±Inf) | ✓ | ✓ | 200k ✓ |
| `soft_sitofp` i64→F64 | ✓ | n/a | n/a | n/a | n/a | n/a | n/a (exponent ≤ 1086 always fits) | n/a | ✓ | 100k ✓ |
| `soft_fptosi` F64→i64 | ✓ (→0) | **→0 (LLVM poison-like, not Julia-`throw`)** | **→0** | **→0** | ✓ | n/a | **OOB wraps to typemin** | n/a | (trunc toward zero) | spot ✓ within range |
| `soft_trunc` (fround.jl) | ✓ | ✓ | ✓ | **doesn't quiet (Julia hw does)** | ✓ | n/a | n/a | n/a | n/a (trunc) | spot ✓ |
| `soft_floor` | ✓ | ✓ | (inherits from trunc+fadd) | **doesn't quiet** | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_ceil`  | ✓ | ✓ | (inherits from trunc+fadd) | **doesn't quiet** | ✓ | n/a | n/a | n/a | n/a | spot ✓ |
| `soft_exp` | ✓ | ✓ | n/a (flushes to NaN) | n/a | ✓ | ✓ (specialcase) | ✓ | ✓ | ≤1 ULP vs Base.exp | 50k — 459 off-by-1 (~0.9%) |
| `soft_exp_fast` | ✓ | ✓ | n/a | n/a | ✓ | flushes to 0 | ✓ | ✓ | ≤1 ULP vs Base.exp (FTZ in subnorm range) | UNTESTED exhaustively |
| `soft_exp_julia` | ✓ | ✓ | n/a | n/a | ✓ | ✓ | ✓ | ✓ | bit-exact vs Base.exp (FMA HW) | 50k ✓ |
| `soft_exp2` / `_fast` / `_julia` | (parallel to soft_exp) | | | | | | | | | |

Ops missing entirely:
- `soft_round` (roundToIntegralTiesToEven, i.e. Julia `round`): NOT IMPLEMENTED.
- `soft_fcmp_{ogt,oge,one,ord,uno,ueq,ult,ule,ugt,uge}`: NOT IMPLEMENTED.
  Only `oeq`, `olt`, `ole`, `une` exist. LLVM lowering must compose these
  from the 4 primitives — verify this is actually done, not silently
  returning 0.
- Float32 native arithmetic (`soft_fadd_f32`, etc.): NOT IMPLEMENTED.
  Any Float32 op in user code is lowered as fpext → fadd64 → fptrunc, which
  double-rounds (not IEEE-conformant for Float32 semantics).
- Float16: NOT IMPLEMENTED.
- `soft_frem` / `soft_mod` (IEEE 754 remainder): NOT IMPLEMENTED.
- `soft_log`, `soft_log2`, `soft_sin`, `soft_cos`, etc.: NOT IMPLEMENTED
  (noted only for future scope).

---

## 2. Findings (prioritized)

### CRITICAL

None. The repo has no fully-broken ops; bugs are precision/canonicalization
divergences, not algorithmic failures.

### HIGH

**H1 — `soft_fmul` drops precision on subnormal-operand inputs (1–2 ULP, ~11% of such inputs).**

`src/softfloat/fmul.jl:14-206`

The 53×53 mantissa multiply assumes `ma, mb` have their leading 1 at bit 52
(IEEE normalized). For subnormal operands, `ma = fa` has its leading 1
strictly below bit 52. The product's MSB then lands below bit 104/105,
the `msb_at_105` check produces wrong shift, and `_sf_normalize_clz` only
left-shifts the extracted-but-truncated 56-bit `wr` — bits that were
discarded when extracting `[105:50]` are not recoverable, producing 1–2
ULP error.

Empirical confirmation (Random.MersenneTwister seed 42, 1M random UInt64
pairs):
```
fmul subnormal path: bad=110/966  (11.4%)
```

Example failing pair:
```
a = 0xE4D9C356E967BECD   (normal, ≈ -6.52e177)
b = 0x8000B051DB6FC2B8   (subnormal, ≈ -9.58e-310)
hw  = 0x24B1BE88A451D1E8
soft= 0x24B1BE88A451D1E6   (2 ULP low)
```

**The comparable code path in `soft_fdiv` (fdiv.jl:42–43) and `soft_fma`
(fma.jl:67–69) correctly pre-normalizes via `_sf_normalize_to_bit52`
before the arithmetic.** `soft_fmul` is the lone arithmetic op missing
this call. Fix:

```julia
# After computing ma, mb, ea_eff, eb_eff in fmul.jl:
(ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)
(mb, eb_eff) = _sf_normalize_to_bit52(mb, eb_eff)
# Then result_exp = ea_eff + eb_eff - BIAS as before.
```

This bug will silently produce wrong answers in any reversible soft-float
circuit that multiplies into or by a subnormal — including any Bennett-
compiled polynomial near zero, division (if `soft_fdiv` ever forwards to
fmul), gradient calculations with tiny scales, etc.

**Why existing tests miss it:** `test_softfmul.jl`'s random test samples
`a, b ∈ [-100, 100]` uniformly (line 85), which never produces
subnormals. The explicit edge-case tests at lines 70–74 only cover
`(smallest_subnormal) × {1, 2, tiny}`, all of which underflow to zero
or to another smallest-subnormal — the bug doesn't trip.

**H2 — `soft_fpext` fails to quiet signaling NaN, diverging from hardware on ~50% of Float32 NaN inputs.**

`src/softfloat/fpconv.jl:62`

```
nan_result  = sign64 | UInt64(0x7FF0000000000000) | (UInt64(fa) << 29)
```

Does not force bit 51 (the Float64 quiet bit). IEEE 754-2019 §5.4.1
requires that `f32→f64` convert **signaling NaN to quiet NaN** (setting
the quiet bit). Hardware (LLVM codegen, Julia `Float64(::Float32)`) does
this. The `soft_fptrunc` sibling (line 148) correctly forces the quiet
bit — the asymmetry is clearly an oversight.

Empirical (Random.MersenneTwister seed 123, 1000 random F32 NaN inputs):
```
fpext NaN differs: 497 / 1000   (all due to missing quiet-bit)
```

Example:
```
f32 = 0x7FAE8E48   (sNaN, payload 0x2E8E48)
hw  = 0x7FFDD1C900000000   (quiet bit set)
sf  = 0x7FF5D1C900000000   (quiet bit NOT set, still signaling)
```

Fix: OR in the quiet bit:
```julia
nan_result  = sign64 | UInt64(0x7FF8000000000000) | (UInt64(fa) << 29)
#                                   ^^^^ set bit 51
```

### MEDIUM

**M1 — NaN sign and payload not preserved for any arithmetic op.**

All of `soft_fadd`, `soft_fsub`, `soft_fmul`, `soft_fdiv`, `soft_fma`,
`soft_fsqrt` canonicalize every NaN output to `QNAN =
0x7FF8000000000000`. Hardware behavior differs in two ways:

1. **NaN sign:** x86-64 (and Julia codegen) produces the "indefinite"
   negative NaN (`0xFFF8...`) for invalid operations (Inf−Inf, Inf/Inf,
   Inf·0, 0/0, sqrt(-x)). Soft produces positive.
2. **NaN payload:** when a NaN is on the input side of a finite
   operation (e.g. `1.0 + qNaN`), hardware propagates the input NaN's
   payload (only setting the quiet bit if the input was sNaN). Soft
   discards the payload and returns canonical `QNAN`.

Empirical (200k random UInt64 pairs, seed 1): **182 out of 200k** pairs
produce a NaN where soft differs from hw by sign/payload, across every
op. Soft_fmul had an extra 23 *structural* (non-NaN) failures (the H1
bug).

Concrete bug evidence:
```
Inf + (-Inf):  hw=0xFFF8000000000000   sf=0x7FF8000000000000
Inf * 0:       hw=0xFFF8000000000000   sf=0x7FF8000000000000
0 / 0:         hw=0xFFF8000000000000   sf=0x7FF8000000000000
1 + qNaN(payload=DEADBEEF):
               hw=0x7FFDEADBEEF00001   sf=0x7FF8000000000000
1 + sNaN:      hw=0x7FF8000000000001   sf=0x7FF8000000000000
```

IEEE 754-2019 doesn't **strictly** require NaN sign consistency (§6.3
says sign of NaN is not interpreted), but Julia's `Base.+, *, /, fma,
sqrt` do preserve payload, and CLAUDE.md §13 demands bit-exactness
against Julia. These are bit-exactness failures. For quantum-control
downstream (`when(qubit) do f(x)`), the payload probably doesn't
propagate semantically, but sign-of-NaN differences will surface as
mismatched Toffoli outputs during simulation.

Fixes require adding NaN-input passthrough logic at the top of each op's
select chain:
```julia
# Preference: pass through first NaN operand with quiet bit set.
a_is_nan = ...
nan_pass = (a | QUIET_BIT)  # or (b | QUIET_BIT) if only b is NaN
result = ifelse(any_nan, nan_pass, result)  # not canonical QNAN
# And: for Inf-Inf / Inf*0 / 0/0 / sqrt(neg), emit 0xFFF8000000000000 not QNAN.
```

**M2 — `soft_trunc`, `soft_floor`, `soft_ceil` don't quiet sNaN on output.**

`src/softfloat/fround.jl:38-42`

`soft_trunc`'s `is_special` branch returns `a` unchanged. Julia's
`Base.trunc(x::Float64)` DOES quiet sNaN to qNaN:
```
sNaN input:  0x7FF0000000000001
hw trunc:    0x7FF8000000000001   (quiet bit set)
soft_trunc:  0x7FF0000000000001   (unchanged — STILL signaling)
```

Fix: in the `is_special` branch, OR the quiet bit into the fraction:
```julia
ifelse(is_special, a | UInt64(0x0008000000000000), ...)
```

**M3 — `soft_fptosi` silently returns sentinel values on NaN/Inf/OOB, not Julia-compatible.**

`src/softfloat/fptosi.jl`

Current behavior:
```
soft_fptosi(NaN)   → 0         (LLVM "poison" ≠ Julia throw)
soft_fptosi(+Inf)  → 0
soft_fptosi(-Inf)  → 0
soft_fptosi(1e20)  → 7766279631452241920  (partial shift, not typemax)
soft_fptosi(Float64(typemax(Int64)))  → typemin(Int64) = -9.22e18
```

The last is particularly insidious: converting a large positive double
that was produced by `soft_sitofp(typemax(Int64))` **silently wraps to
negative** — a round-trip that destroys the value. Julia's
`unsafe_trunc(Int64, x)` behaves similarly (since this is LLVM
`fptosi`'s undefined behavior), but `Int64(x)` or `trunc(Int64, x)`
throw `InexactError`. The docstring claim "Behavior on Inf, NaN,
out-of-range. LLVM's behavior is 'poison'" is consistent with
`unsafe_trunc`, but any downstream code calling `Int64(x)` and hitting
these cases will be silently wrong instead of crashing.

Fix: document explicitly that this is `unsafe_trunc` semantics, or add
the explicit-range-clamp-and-saturate behavior used by Clang's
`-fsanitize=float-cast-overflow`.

**M4 — `soft_exp` is not bit-exact vs `Base.exp` (≤1 ULP off ~0.9% of the time).**

`src/softfloat/fexp.jl:358-418`

Empirical (50k random inputs in [-20, 20], seed 8):
```
soft_exp:        bad=459/50000  max_ulp=1
soft_exp_julia:  bad=0/50000    max_ulp=0   ✓ bit-exact
```

This is documented in the file header ("≤1 ulp vs `Base.exp`"), but the
`exp_julia.jl` sibling demonstrates bit-exactness is achievable via
FMA-based muladd. If CLAUDE.md §13 demands bit-exactness, use the Julia
variant as the default bound to `Base.exp(::SoftFloat)` (which is
already done at `Bennett.jl:248`). Recommend: **retire `soft_exp`** or
clearly label it "musl-compatible, not Julia-compatible."

**M5 — Only 4 of 14 LLVM fcmp variants implemented.**

`src/softfloat/fcmp.jl`

Implemented: `oeq, olt, ole, une`.
Missing: `ogt, oge, one, ord, uno, ueq, ult, ule, ugt, uge`.

If LLVM lowering (in `lower.jl` fcmp handler) composes these correctly
from the available primitives, this is just a code-smell nit. If
lowering silently emits a wrong comparison or falls back to zero, this
is a CORRECTNESS BUG. **VERIFY.** Grep `lower.jl` for `fcmp` handling
to confirm all 14 predicates dispatch correctly.

**M6 — `_sf_handle_subnormal`'s flush-to-zero threshold is `shift_sub >= 56`, which may flush values that would correctly round up to smallest subnormal.**

`src/softfloat/softfloat_common.jl:100-118`

`flush_to_zero = shift_sub >= Int64(56)` — when the subnormal right-
shift distance reaches 56, all 56 bits of `wr` have been shifted out,
and the result is hard-flushed to `±0` (sign-only `flushed_result`).
But with round-nearest-even, a value just below smallest subnormal
should round UP to smallest subnormal when its top bit was 1. The
sticky-bit logic preceding the flush (`lost_sub`) captures this only
up to `shift_sub = 55`. At `shift_sub = 56` and the input had bit 55
set (the would-have-been round bit), the correct RTNE result is
smallest subnormal (`frac = 1`), not zero. (Strictly: the half-way
tie rounds to `frac = 1` via ties-to-even since frac = 0 is "more
even"; but values > half-way should round up.)

No empirical failure was constructed (the fdiv/fmul/fma tests with
subnormal outputs passed); this may be compensated elsewhere, but the
threshold should be scrutinised. Recommend a unit test that constructs
an operation whose true result is in `[2^-1075 + ε, 2^-1074]` (i.e.
strictly greater than half of smallest subnormal) and verifies it
rounds UP to `2^-1074`, not down to 0.

### LOW

**L1 — `soft_round` (round-half-to-even on float) not provided.**

Users calling `Base.round(x::SoftFloat)` hit the default fallback (which
uses `Base.floor/ceil` and arithmetic) — may work but unverified and
inefficient.

**L2 — No Float32 native arithmetic. All Float32 ops double-round via fpext/fptrunc.**

Even if `f32_add(a, b) = fptrunc(fadd64(fpext(a), fpext(b)))` seems
innocent, it's only correctly-rounded if the fadd64 result is at
Float32 precision — which is not true in general (cf. Kahan's
double-rounding theorem). For correctness-critical Float32 work this
would be a real bug. Currently the repo has no tests compiling user
code with Float32, so this is latent risk, not active harm.

**L3 — `soft_exp_fast` / `soft_exp2_fast`: subnormal inputs flushed to 0 instead of correct subnormal output.**

Documented clearly. Surfaced here because users must understand "fast"
means "not bit-exact on ~2% of the input range." This belongs in
`CLAUDE.md §13`'s bit-exactness policy as an explicit exception.

**L4 — fdiv's `_sf_round_and_pack`-produced `overflow_result` is discarded (line 82: `_overflow_result`) and replaced with the locally-computed `inf_result` (line 87).**

`src/softfloat/fdiv.jl:82-87`

Both compute `(result_sign << 63) | INF_BITS`, so the output is
identical — dead code, not a correctness issue. Clean up.

**L5 — `_sf_normalize_to_bit52` explicitly notes its zero-input behavior is pathological.**

`softfloat_common.jl:14-31` docstring: "m == 0 yields a pathological
result (63 shifts, no leading 1 found) but callers handle zero inputs
via the select chain before using `m`."

This is correct as documented — but fragile. Any future caller not
aware of this precondition will produce wrong exponent for `m = 0`.
Recommend adding `ifelse(m == 0, (UInt64(0), e), (...))` at the end,
or an `@assert m != 0` for debug builds.

### NIT

**N1 — `fneg.jl:6` uses XOR — fine. `soft_fneg(NaN)` correctly preserves payload including sNaN status. ✓**

**N2 — `test_softfmul.jl:85` random sample is uniform in [-100, 100], avoiding subnormals.** This is the test-methodology gap that hid H1. Recommend adding a separate `@testset` with random UInt64 inputs uniformly sampled across the whole bit range (including sign, subnormal, NaN, Inf patterns). Same fix applies to `test_softfdiv.jl`, `test_softfadd.jl`.

**N3 — Gate counts for soft_fmul.** CLAUDE.md notes baseline gate counts — if H1 is fixed by adding `_sf_normalize_to_bit52` calls, `gate_count(reversible_compile(soft_fmul, (UInt64, UInt64)))` will increase (by ~6 stages × mantissa width). This is a **regression-locked baseline** per CLAUDE.md §6 — expect the fix to bump the baseline.

**N4 — `fexp.jl` vs `fexp_julia.jl` coexistence.** Two exp implementations; `Bennett.jl:248` binds `Base.exp(::SoftFloat) = soft_exp_julia`. So `soft_exp` is only reachable if a user calls it directly. Either document `soft_exp` as "musl-compatible alternative for reference" or retire it.

**N5 — Inf×0 NaN sign follows product-sign-XOR in hw, but soft always emits +QNAN.** This is part of M1 but worth flagging: hw's `-Inf * +0 = -NaN`, `+Inf * +0 = +NaN`. For operations that "should" produce NaN, hardware's sign rule is "sign of product would-be" — soft flattens to positive.

---

## 3. Verification empirical evidence

Random bit-pattern tests performed at review time:

```
fadd: 200k random UInt64 pairs: 182 NaN-payload/sign differences, 0 structural
fsub: 200k                      182                              , 0
fmul: 200k                      182                              , 23 structural (H1)
fdiv: 500k                      (several hundred NaN)           , 0
fma:  300k                      (several hundred NaN)           , 0
fsqrt: 500k positive           0 NaN, 0 structural               ✓
sitofp: 100k                   0 structural                      ✓
fpext:  100k                   204 NaN-payload (quiet-bit)       ✗ (H2 causes ~50% of F32-NaN inputs to fail)
fptrunc: 200k                  0                                 ✓
fcmp (all 4): spot-checked ±0, ±Inf, NaN combinations: ✓
fround (trunc/floor/ceil): spot-checked subnormal, large, ±0, NaN: ✓ except sNaN not quieted (M2)
soft_exp: 50k in [-20,20]: 459/50000 off-by-1 ULP
soft_exp_julia: 50k in [-20,20]: 0/50000 — bit-exact ✓
```

Subnormal-stratified:
```
fmul on pairs with ≥1 subnormal: bad=110/966 (11.4% — H1)
fma  on tuples with ≥1 subnormal: bad=0/300 ✓
fma  on subnormal-output-expected tuples: bad=0/100000 ✓
fsqrt on subnormal input:       bad=0/103 ✓
```

Cross-op consistency:
```
fma(a, b, 0) vs fmul(a, b): differ in 16/200k (expected from single-rounding; but
  also mixing in fmul's subnormal bug).
```

All tests use Random.MersenneTwister with fixed seeds. Full reproduction
commands are embedded in the review commit history.

---

## 4. Test-coverage gaps

1. **No whole-UInt64-range random tests in the existing test files.** All
   random tests use `reinterpret(UInt64, rand() * K - K/2)`, which
   produces normal Float64s in a bounded range. Subnormals, ±Inf, NaN,
   max/min-magnitude normals are NEVER reached via random sampling. This
   is the #1 methodology gap; adding `rand(rng, UInt64)` would have
   caught H1 on the first test run.

2. **No NaN-payload preservation tests.** Every NaN-input test checks
   `isnan(result)`, never `result_bits == expected_bits`. This masks M1
   entirely.

3. **No cross-op consistency tests.** E.g. `soft_fadd(x, soft_fneg(y)) ==
   soft_fsub(x, y)`, `soft_fmul(x, x) == soft_fma(x, x, 0)` (fails only
   at double-rounding ties — which IS the point).

4. **No ancilla-hygiene test on a soft-float-using function compiled
   through Bennett.** `test/test_float_circuit.jl` does have
   `verify_reversibility`, but only on simple polynomials. No test
   compiles `soft_fdiv` or `soft_fma` itself and verifies ancillae
   return to zero exhaustively. Given the scale (fmul ~thousands of
   gates; fma ~36k), any leaked ancilla would be catastrophic — but
   undetected by the current suite.

5. **No regression test for the subnormal flush-to-zero boundary** (M6).

6. **Float32 arithmetic and Float16 arithmetic: unimplemented AND untested.**
   Any user function using `Float32 + Float32` lowers into a chain that
   double-rounds. No test validates this.

---

## 5. Recommended fix priorities

1. **H1 (fmul subnormal)** — add two lines to `src/softfloat/fmul.jl`
   after line 49. Add a regression test with whole-UInt64-range random
   sampling. Update gate-count baseline.

2. **H2 (fpext sNaN quiet)** — one character change to
   `src/softfloat/fpconv.jl:62`. Add sNaN→qNaN conversion test.

3. **M1 (NaN sign/payload)** — requires adding NaN-input-passthrough
   select-chain branches to each op (fadd/fsub/fmul/fdiv/fma/fsqrt).
   Non-trivial; ~10 LoC per op. Decide scope: is CLAUDE.md §13's
   bit-exactness claim ASPIRATIONAL or BINDING? If binding, this is a
   required fix.

4. **M2, M3 (sNaN in trunc/floor/ceil; fptosi sentinel)** — document or
   fix. Low-priority if downstream code never hits these paths.

5. **Test infrastructure overhaul** — add whole-UInt64-range random
   testing across all ops. Enforce bit-exact comparisons (not
   `isnan(result)`). Add cross-op consistency tests. Add gate-count
   baselines.

6. **Audit `lower.jl` fcmp path** (M5) — ensure all 14 predicates resolve
   to correct soft_fcmp_* composition.

---

## 6. Summary for CLAUDE.md §13

Current state: CLAUDE.md §13 says "Every soft-float function must be
bit-exact against Julia's native floating-point operations." **This is
not currently true.** Either:

(a) **Strengthen the implementation** to match the claim: fix H1, H2,
M1–M4, add missing ops. Substantial work (~2 days).

(b) **Weaken the claim** to reflect reality: "Every soft-float function
must be within 1 ULP of Julia's native operations on finite normal
inputs. NaN/sNaN canonicalization and sign-of-NaN for invalid ops may
differ; subnormal-input precision is not guaranteed." And update the
tests' tolerance accordingly.

Shipping bit-exactness requires **option (a)**. Any downstream
Sturm.jl/quantum-control work that tests simulator output against
reference Julia-computed values will see spurious mismatches until
these are resolved.
