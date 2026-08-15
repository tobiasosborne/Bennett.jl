# C4 — Soft-float library architecture review

**Scope:** `src/softfloat/` (35 files, 8,179 LOC) + `src/softfloat_dispatch.jl` (207 LOC),
plus their coupling surfaces in `src/callees.jl`, `src/extract/instructions.jl`,
`src/lowering/call.jl`, and `test/test_softf*.jl` (~5,600 LOC across 35 test files).
Reviewer stance: adversarial, read-only, from-scratch-oriented.

---

## 1. What this area actually does

### 1.1 The stated purpose vs. the real one

The stated purpose (CLAUDE.md §13) is "IEEE 754 operations in pure integer arithmetic,
bit-exact against Julia's native floating-point operations." That is accurate for the six
core arithmetic primitives and misleading for everything else. The real shape is:

| Tier | Functions | Actual contract | Verified how |
|---|---|---|---|
| A. Core arithmetic | `soft_fadd/fsub/fmul/fdiv/fma/fsqrt` | **bit-exact vs hardware**, all 2^64 bit patterns in scope | `test_9x75_*` (5k raw-bit fuzz/op), `test_m63k_*` (strict-bit + NaN payload) |
| B. Predicates/conversions | 10 `soft_fcmp_*`, `fpext/fptrunc/fptosi/fptoui/sitofp`, 5 rounding, 6 min/max | bit-exact vs hardware/LLVM semantics | per-op test files |
| C. Transcendentals (musl-tracking) | `exp, exp2, log, log2, log10, pow, sin, cos, tan, atan, atan2, asin, acos, sinh, cosh, tanh, asinh, acosh, atanh, log1p, expm1` (~22 math functions) | **≤1–2 ULP vs `Base.*`**, bit-exact vs musl/openlibm | ULP-tolerance sweeps + subnormal sweeps |
| D. Julia-tracking doubles | `soft_exp_julia, soft_exp2_julia, soft_pow_julia` | bit-exact vs `Base.exp/exp2/^` *on FMA hardware* | `test_softfexp_julia`, `test_softfpow_julia` |
| E. Cost-reduced doubles | `soft_exp_fast, soft_exp2_fast` | = tier C outside the subnormal-output binade, FTZ inside | `test_softfexp.jl:172-186` |

So the "bit-exact" contract in CLAUDE.md §13 covers tier A/B only; tiers C/D/E have three
*different* oracles (hardware, musl, Base), and the library ships **three parallel exp
implementations and two parallel pow implementations** to satisfy them. That is a real
design decision, not an accident — but it is undocumented as a *policy* and it doubles the
transcendental surface.

### 1.2 The actual architectural constraint

Every design choice in this directory is downstream of one requirement that is nowhere
stated as a first-class architectural invariant: **the code must lower to a straight-line,
branch-free LLVM IR graph whose only intrinsics the extractor already understands.**

Three consequences follow, and they explain nearly all of the code's shape:

1. **Everything is `ifelse`, never `if`.** Every function computes *all* paths and selects
   with a "last-write-wins" `ifelse` cascade (`fadd.jl:121-133`, `fexp.jl:330-339`,
   `ftanh.jl:172-181`). This is required because Bennett's phi resolution is the known
   correctness hot-spot (CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK").
   It is *justified* domain complexity.
2. **Cost is total, not expected.** `_rp_rem_pio2` (`fsin.jl:578-658`) eagerly evaluates
   four Cody-Waite 2c reductions, the three-level Cody-Waite extended reduction, **and** the
   full Payne-Hanek 128-bit multi-precision path, then selects. Result: `soft_sin` compiles
   to ~11M gates (1.6M NOT / 7.1M CNOT / 2.3M Toffoli), ~45 s compile time
   (`worklog/055_2026-05-03_3mo_sin_cos.md:117-123`).
3. **Source style is dictated by LLVM's optimizer.** `extract_parsed_ir` defaults to
   `optimize=true` (`src/extract/entry.jl:54`), so LLVM's SLP vectorizer runs on this code.
   Two sibling `soft_fdiv` calls with no data dependency get vectorized into `<4 x i64>` +
   `llvm.smax.v4i64`, which the extractor rejects. The documented mitigation is *to write the
   numerics differently* — replace a second `soft_fsub` with a SIGN_BIT XOR
   (`worklog/059_2026-05-06_7goc_soft_atan2.md:110-124`, "qpke gotcha #1"). Numerical source
   contorted to dodge a downstream extractor limitation is textbook accidental complexity.

### 1.3 Structure

- `softfloat.jl` — 71-line module wrapper: 34 `include`s + one `export` list.
- `softfloat_common.jl` (466 LOC) — the only genuine shared layer: bit constants, NaN
  propagation, two CLZ normalizers, subnormal handling, round-and-pack, and eight 128-bit
  (hi,lo) helpers.
- One file per operation otherwise. Files are self-contained: coefficients as module-level
  `const`s, a `_xxx_tab_lookup` helper where a table is needed, then one monolithic function.
- Consumption: `src/callees.jl` registers ~60 `soft_*` as known callees;
  `src/extract/instructions.jl` maps ~220 `llvm.*` intrinsic names onto them;
  `src/softfloat_dispatch.jl` provides the `SoftFloat` sugar struct for the
  `reversible_compile(f, Float64)` entry point.
- **Inlining is by value, not by reference:** `lower_call!` (`src/lowering/call.jl:83-172`)
  re-emits the callee's *entire gate list* at every call site. `soft_fmul` = 149,456 gates
  (BENCHMARKS.md:27); a kernel with 20 multiplies pays 20× that. There is no circuit-level
  subroutine, no shared-uncompute call/return. This is *the* reason transcendentals are
  8-figure gate counts.

---

## 2. Antipatterns, tech debt, accidental complexity

### 2.1 Genuine antipatterns (unambiguous)

**(a) Abandoned first draft left in the source, with the thinking-out-loud comments.**
`fmul.jl:99-136`. Lines 95-105 compute `prod_lo`, `carry_lo`, `cross_hi`, `pp_hh_shifted` —
all dead. Line 105 says *"Let's redo properly."*, line 107 *"Restart assembly more
carefully:"*, line 120 *"Let's just do it with add-with-carry."* The live code is 126-136.
This is the single hottest function in the library (149k gates, in every transcendental) and
it ships with ~40 lines of abandoned scaffolding. Dead code here is not free: it is dead
*only* because LLVM's DCE removes it, which means correctness of the gate count depends on
optimizer behaviour rather than on the source.

**(b) A literal placeholder ternary that does nothing, shipped.**
`fsin.jl:614-617`:
```julia
on_3pio2 = (xhp & UInt32(0xFFFFF)) == UInt32(0x21FB) ?
           UInt64(0) : UInt64(0)   # placeholder — we'll use explicit checks
```
Both arms are `UInt64(0)`; `on_3pio2` is never read. Line 618 then says *"Actually use
explicit equality vs..."*. In the most correctness-critical range-reduction dispatcher in
the library.

**(c) Unused unpacked fields.** `fsin.jl:684` (`sa` in `soft_sin`) and `fsin.jl:741` (`sa`
in `soft_cos`) are computed and never used. Minor, but symptomatic: the "unpack preamble" is
copy-pasted rather than derived.

**(d) Silent const shadowing across files in the same module.**
`_MAX_EXP_E_BITS`, `_MIN_EXP_E_BITS`, `_MAX_EXP_2_BITS`, `_MIN_EXP_2_BITS` are each defined
**twice** — `fexp.jl:176-180` and `fexp_julia.jl:91-107` — inside the single
`module SoftFloatLib`. `fexp_julia.jl` is included second (`softfloat.jl:24-25`), so its
definitions win *for `soft_exp` too*. Today the values coincide so nothing breaks. On Julia
1.12 a divergent edit produces **no warning and no error** (verified: `const Z=1; const Z=2`
in a module is silently accepted on 1.12.5) — the overflow threshold of the musl-tracking
`soft_exp` would silently become whatever `fexp_julia.jl` says. This is a live footgun in the
exact code path (`soft_exp`'s overflow boundary) that a previous bug campaign had to fix.

**(e) Documentation counters that are wrong three ways.** `softfloat.jl:50` says "Public
surface: 32 IEEE-754 primitives"; CLAUDE.md says "39 public `soft_*` primitives"; the actual
export list is **60 names**. Header comments count `include`s wrong too. Trivial to fix,
but it means the module header cannot be trusted as a map.

**(f) Deliberate baseline lock-in preventing a known simplification.**
`softfloat_common.jl:229-251` documents that the hand-rolled `(hi,lo)` 128-bit helpers were
justified by a claim ("UInt128 emits `__udivti3`") that has been **empirically disproved**
on Julia 1.12, and then says they are kept anyway because replacing them "would shift
soft_fma's gate-emission profile and require re-measuring every soft_fma baseline
(CLAUDE.md §6)." The regression-baseline policy is now actively preventing a
simplification that the project has already proven safe. That is tech debt with a lock on it.

**(g) Known-incorrect rounding, dispositioned as "doc-only".**
`softfloat_common.jl:148-172` (Bennett-xiqt): `flush_to_zero = shift_sub >= 56` is
acknowledged as theoretically RTNE-incorrect at `shift_sub == 56` with bit 55 set; the
disposition is "not triggered by any current caller," pinned by an *empirical agreement*
test. A from-scratch v2 should not inherit a rounding rule whose justification is "no caller
currently reaches it."

**(h) Composition without CSE awareness in the comparison family.**
`soft_fcmp_ule = uno | ole = uno | (olt | oeq)` (`fcmp.jl:183-185`) re-derives the
NaN classification three times. At the source level this is fine (LLVM CSEs it under
`optimize=true`); it is listed here because it is *only* fine because of the optimizer, and
the project's own rule 5 tells agents to test with `optimize=false`, where the cost is real.

**(i) The "branchless" contract is violated by the largest function.**
`soft_pow_julia` (`fpow_julia.jl:445-513`) uses early `return`s and `if` blocks throughout,
and `_pj_pow_body_int` (`fpow_julia.jl:388-440`) contains a genuine data-dependent
`while n > 1` loop with an inner `if`. So the library's headline invariant ("fully
branchless — required for correct reversible compilation") is not a library-wide invariant
at all; one member depends on the loop unroller and the phi resolver that everything else
was written to avoid. Nothing in the code or tests asserts the branchless property.

**(j) Table-lookup written to trigger a compiler pattern-match.**
`_exp_tab_lookup` (`fexp.jl:187-191`) is `let T = _EXP_TAB; @inbounds T[idx+1]; end`, and the
comment says the `let`-rebind "is the documented requirement for QROM dispatch" — without it
the lookup "would fall through to MUX EXCH (~10× more gates)"
(`worklog/017_...:161-164`). A numerical kernel whose *syntax* selects a circuit-synthesis
strategy is a leaky abstraction; the strategy choice belongs in the lowering, keyed on IR
shape, not on a `let` in the numerics.

### 2.2 Massive structural duplication (quantified)

- The special-case unpack + classify preamble
  (`sa`/`ea`/`fa` + `a_nan`/`a_inf`/`a_zero`) appears **32 times** across 23 files
  (grep: `(ea == UInt64(0x7FF)) & (fa != UInt64(0))`). Every one is hand-written.
- The trailing "last-write-wins" `ifelse` cascade appears once per public function (~60).
- **`fexp.jl` contains four near-identical bodies**: `soft_exp2` (281-341), `soft_exp`
  (383-443), `soft_exp2_fast` (476-526), `soft_exp_fast` (554-606). The `_fast` variants are
  verbatim copies of their parents minus one `ifelse` line and one call. 606 lines where
  ~180 + parameterisation would do.
- **Three separate log tables** hand-transcribed: `_LOG_TAB` (`flog.jl:84-218`, 256 entries),
  `_POW_LOG_TAB_INVC/LOGC/TAIL` (`fpow.jl:72+`, 3× 128 entries), `_PJ_T_LOG_TAB`
  (`fpow_julia.jl`, 128 pairs). Plus two exp tables (`_EXP_TAB` 256, `_JL_J_TABLE` 256) and
  `_RP_INV_2PI` (19). ≈1,200 hand-copied hex constants, unverified against their upstream
  source by any test.
- `fmin.jl`: four bodies (`fminimum`/`fmaximum`/`fmin`/`fmax`, lines 29-133) that differ by
  one comparison direction and one NaN rule, plus two pure forwarders
  (`soft_minimumnum`/`soft_maximumnum`, 157-170) written as full `function … end` bodies
  *specifically so the callee registry sees them as distinct generic functions*
  (`fmin.jl:142-146`) — the registry's identity model forcing source duplication.
- `fround.jl`: five near-identical rounding functions (295 LOC).

Counter-example proving the alternative works: `_exp_impl_julia`
(`fexp_julia.jl:131-205`) is **one** parameterised kernel taking 10 constant arguments, from
which `soft_exp_julia` and `soft_exp2_julia` are two 5-line calls. The shared-kernel pattern
was already invented here and then not applied anywhere else.

### 2.3 Complexity that is genuinely justified by the domain

To be fair, a large fraction of what looks ugly is not:

- **Branchless everything.** Non-negotiable given the phi-resolution risk. The `ifelse`
  cascades, the eager computation of unreachable paths, the `clamp`-guarded shift amounts
  (`fadd.jl:76`, `_shiftRightJam128` `softfloat_common.jl:373-412`) are all correct responses
  to "shift-by-≥64 is UB and every path must be evaluated."
- **Substitute-sentinel patterns.** `_sf_normalize_to_bit52` substituting `IMPLICIT` for
  `m == 0` and restoring at exit (`softfloat_common.jl:68-105`); `_rp_paynehanek` clamping
  negative table indices to 0 and masking the result (`fsin.jl:487-502`). These are the
  correct branchless idiom for "this path is unreachable but must still be evaluated safely."
  The comment at `fsin.jl:485-486` is important: without clamping, LLVM emits `unreachable`
  for the impossible-but-actually-evaluated branch.
- **Full Payne-Hanek.** Expensive, but required for ≤2 ULP over the full f64 range; the
  alternative (Cody-Waite only) is simply wrong above 2^28·π/2.
- **The extended-precision (hi, lo) idioms** — Dekker splits in `flog.jl:358-375`, the
  `_exp_specialcase_underflow` reconstruction (`fexp.jl:217-241`) — are what the reference
  libm does and are load-bearing for the last ULP.
- **The 56-iteration restoring division loop** (`fdiv.jl:91-98`) and the 64-iteration
  digit-recurrence sqrt (`fsqrt.jl:80-90`) are the right algorithms for a *reversible* target:
  they are uniform, data-independent, and produce a clean sticky bit. Newton-Raphson would
  need a seed table and variable iteration count.
- **The Kahan no-midpoint argument** documented at `fsqrt.jl:11-15` — correct, and it is
  exactly the kind of reasoning that must survive a rewrite.

---

## 3. Version coupling (Julia 1.12 / current LLVM)

Ranked by blast radius.

**(1) `soft_*_julia` bit-exactness is pinned to Julia 1.12's `Base.Math` internals.**
`fexp_julia.jl` is a line-for-line port of `Base.Math.exp_impl` including the verbatim
256-entry `J_TABLE`; `fpow_julia.jl` ports `Base.:^(::Float64,::Float64)` including
`pow_body`. `ftanh.jl:53-70` copies `Base.tanh_kernel`'s degree-10 coefficients verbatim;
`flog1p.jl`, `fexpm1.jl`, `fsinh.jl`, `fcosh.jl` similarly adapt Julia stdlib regime splits.
**If Julia 1.13 retunes any of these, the corresponding `test_softf*_julia` bit-exactness
tests fail and the fix is a re-port, not a patch.** This is a standing tax proportional to
the number of `_julia` variants.

**(2) Worse: bit-exactness depends on Julia's `@noinline` annotations and LLVM's
fp-contraction decisions.** `fpow_julia.jl:380-386` states that because Julia's
`pow_body(::Float64, ::Integer)` is `@noinline`, its `muladd`s are *not* contracted into FMA,
so the port must use `soft_fadd(soft_fmul(...))` (two roundings) rather than `soft_fma`
(one). A change to that annotation, or to LLVM's `contract` handling, silently changes the
oracle. This is the most fragile coupling in the whole subsystem, and it is invisible from
the call site.

**(3) LLVM optimizer shape is part of the contract.** `optimize=true` is the default in
`extract_parsed_ir`, so the SLP vectorizer, `llvm.smax`/`llvm.smin` formation from `clamp`,
and instcombine all run before extraction. The known failure is `<4 x i64>` +
`llvm.smax.v4i64` from parallel identical `soft_*` calls (Bennett-ao66, still open). An LLVM
upgrade that vectorizes more aggressively will break extraction of code that is numerically
unchanged. `src/extract/vectors.jl` exists to re-scalarise, but only for the forms enumerated
so far.

**(4) Julia 1.12 removed the const-redefinition safety net.** Verified on 1.12.5: redefining
a module-level `const` with a *different* value is accepted silently. This turns §2.1(d) from
a load-order curiosity into a real hazard, and it is new in 1.12 — on ≤1.11 a divergent edit
would at least have warned.

**(5) 128-bit arithmetic.** `softfloat_common.jl:229-251` and `fsin.jl:341-347` both hand-roll
`(hi,lo)` pairs, for two different stated reasons: the compiler-rt claim (disproved on 1.12)
and "LLVM emits i128 *constants* for shift amounts which the IR walker rejects
(Bennett-l9cl)". The second is still live but is a defect in the walker's `IROperand.value ::
Int64`, not a numerical constraint. On any future Julia/LLVM, this stays broken until the
walker widens.

**(6) Hex-float literals and `reinterpret`.** `reinterpret(UInt64, 0x1.62e42fefa39efp-1)`
works from 1.10 onward and is stable — a *good* coupling, and worth keeping.

**What would simplify on 1.13:** native `UInt128` throughout (removing ~10 hand-rolled
helpers in `softfloat_common.jl` + 4 in `fsin.jl`) *if* the walker is fixed; and, if the
rewrite drops the `_julia` variants (see §5b), the Base-internals coupling disappears
entirely.

---

## 4. From-scratch verdict

Assuming code generation is free, the *content* here is worth far more than the *form*. The
numerics have been debugged against ~30k strict-bit assertions and several nasty bug classes;
the file layout, the duplication, and the compiler-shaped source style are all disposable.

### 4.1 KEEP (port close to verbatim)

1. **`softfloat_common.jl` in its entirety, as the v2 kernel layer.** The CLZ normalizers,
   `_sf_handle_subnormal`, `_sf_round_and_pack`, `_shiftRightJam128`, the sentinel-substitute
   idiom. This is the one part that is already the right abstraction. (Fix the flush boundary,
   §2.1(g).)
2. **The six core algorithms**: magnitude-ordered branchless add; 27×26 schoolbook multiply;
   56-step restoring division; 2-bits/iteration digit-recurrence sqrt with the Kahan argument;
   Berkeley-scaled 128-bit FMA. These are correct and correctly reasoned.
3. **The special-case *policy*** — x86 first-operand NaN propagation, `INDEF` for invalid-op,
   force-quiet on passthrough, three-operand FMA precedence
   (`softfloat_common.jl:16-35`). This was hard-won (Bennett-r84x) and matches hardware.
4. **The reference sources and coefficient sets** — musl/AOR for exp/log/pow, FreeBSD SunPro
   for sin/cos/tan/atan, Julia stdlib regime splits for the hyperbolics. Keep the tables;
   re-derive rather than re-transcribe (§5a).
5. **The entire test corpus, essentially verbatim** — see §5c.
6. **The docstring-as-correctness-sketch practice.** `fdiv.jl:8-42` and `fsqrt.jl:8-29` are
   genuinely good: invariant, precondition, why-rounding-is-correct. Port the practice.

### 4.2 DISCARD

1. **The one-file-per-operation layout** and the 32 hand-written unpack preambles.
2. **`soft_exp_fast` / `soft_exp2_fast` as separate source.** They are a cost knob, not an
   algorithm; make FTZ-on-output a *parameter* of the generated kernel.
3. **`_pow_exp_specialcase_underflow = _exp_specialcase_underflow` aliasing**, the
   `soft_minimumnum`/`soft_maximumnum` forwarder-bodies-as-registry-identity trick
   (`fmin.jl:142-146`), and every other construct whose shape exists to satisfy the callee
   registry. Fix the registry's identity model instead.
4. **The dead code and placeholders**: `fmul.jl:99-136`, `fsin.jl:614-617`.
5. **The `let T = TABLE` QROM-triggering idiom.** Replace with an explicit lowering-level
   table intrinsic.
6. **Probably: the `*_julia` variants** (see §5b for the argument).

### 4.3 REDESIGN — sketch

**Layer 0 — a *typed* soft-float IR, not raw `UInt64`.** Today every function takes and
returns `UInt64` and every one re-derives `(sign, exp, frac, class)`. v2 should have an
internal `Unpacked` struct (sign, biased exp, mantissa-with-implicit, class flags) produced by
one `unpack(bits)` and consumed by one `pack_round(...)`. Julia will scalarise the struct
away completely; the classification is computed once per operation instead of 1-4 times, and
the 32 duplicated preambles collapse to one. This alone removes several hundred lines and
several hundred thousand gates per transcendental.

**Layer 1 — a branchless combinator vocabulary.** Formalise what is currently a convention:
```julia
select(cond, then, else_)                # the ifelse discipline
@specialcases result begin               # replaces every hand-rolled cascade
    nan   => propagate_nan(a, b)
    inf   => ...
end
```
with a macro that *enforces* last-write-wins ordering and, critically, emits a compile-time
check that the generated function contains no `br` — closing the gap that let
`soft_pow_julia` ship with real control flow.

**Layer 2 — a table-driven transcendental framework.** See §5a. Every tier-C function is
`argument-reduce → table lookup → polynomial → reconstruct → special-case cascade`. Express
that once; instantiate ~22 times from a spec.

**Layer 3 — cost as a first-class parameter.** Instead of `soft_exp` / `soft_exp_fast` as
separate functions, generate from
`ExpSpec(base=:e, subnormal_output=:exact|:ftz, oracle=:musl)`. Reduction-path selection for
sin/cos should likewise be a *compile-time range assertion*: if the caller can prove
`|x| < 2^28·π/2` (the common case in real numerical code), Payne-Hanek should never be
emitted. Today it always is — that is most of the 11M gates.

**Layer 4 — fix the two upstream defects instead of working around them.**
(i) widen the IR walker's operand value to 128-bit so native `UInt128` can be used;
(ii) either disable SLP for extracted functions or complete the vector re-scalarisation
(Bennett-ao66). Both are cheap relative to the ongoing tax of contorting numerics.

**Layer 5 — circuit-level sharing.** The single largest lever on gate counts is not in this
directory: `lower_call!` re-emits whole gate lists per call site. A reversible
call/uncall (Bennett-style subroutine with shared ancilla frame) would cut transcendental
circuits by roughly the call multiplicity — an order of magnitude for sin/pow. Worth
designing *before* v2's numerics, because it changes what "cheap" means and therefore changes
the algorithm choices.

---

## 5. Specific questions

### (a) Could v2 generate the ~22 transcendentals from a shared kernel + coefficient tables?

**Yes, and the evidence is already in-tree.** Structural analysis:

| Stage | Variation across the 22 | Generatable? |
|---|---|---|
| Special-case classify/cascade | ~5 distinct shapes (exp-like, log-like, odd-symmetric trig, saturating hyperbolic, two-arg) | Yes — one macro, a per-function case table |
| Argument reduction | 4 families: multiply-by-invconst + `+MAGIC−MAGIC` round trick (exp/exp2/pow); integer `ix − OFF` exponent split (log/pow-log); Cody-Waite/Payne-Hanek (sin/cos/tan); regime split on \|x\| (hyperbolics, atan, asin/acos) | Yes — 4 reduction combinators |
| Table lookup | identical pattern everywhere: `T[idx]`, sometimes paired (value, tail) | Yes — one `Table` abstraction, one lowering |
| Polynomial | Horner or Estrin over 3–15 coefficients | Yes — `@evalpoly_soft(z, coeffs...)`; `ftanh.jl:132-151` is 20 lines of hand-unrolled Horner that a macro emits |
| Reconstruction | ~6 forms (`scale·(1+p)`, `k·ln2 + logc + p`, quadrant select, `1 − 2/(e^{2x}+1)`, `x·kernel(x²)`, change-of-base multiply) | Yes — combinator per form |
| Extended-precision fixups | Dekker split, (hi,lo) reconstruction, underflow specialcase | Partly — 3 reusable helpers, occasional bespoke |

Concretely: `soft_sinh`, `soft_cosh`, `soft_tanh` share one skeleton (regime split → poly on
`x²` / exp-formula / saturate) and differ only in coefficients, thresholds, and the exp
formula; that is ~600 LOC today for what is one 60-line kernel plus three ~15-line specs.
`soft_exp`/`exp2`/`exp_fast`/`exp2_fast` are four copies of one kernel. `soft_log2`/`log10`
are already one-liners over `soft_log` (`flog.jl:432,442`).

Realistic estimate: **8,179 LOC → roughly 1,200–1,800 LOC of framework + ~1,000 lines of
declarative specs + the coefficient tables** (which should be *generated* at build time from
Remez/upstream sources into a checked-in artefact, with a test that regenerates and compares —
that also fixes the "1,200 unverified hand-copied hex constants" problem). The two genuine
exceptions that resist generation are `_rp_paynehanek` (`fsin.jl:468-566`) and
`_pj_pow_body_int`'s compensated squaring; keep those hand-written.

The prototype already exists: `_exp_impl_julia` (`fexp_julia.jl:131-205`) is exactly the
"one kernel, constants as parameters" design, and Julia's constant propagation makes the
parameterisation free. The only reason it was not generalised is that each transcendental was
delivered as its own bead by a different agent session, with "mechanical mirror of the
previous one" as the explicit method (`worklog/058_..._ckvj:173-176`). The process produced
the duplication, not the domain.

### (b) Port Berkeley SoftFloat / musl, or compile `Base.Math` straight through the pipeline?

**Porting Berkeley SoftFloat: no for tier A, marginal for the rest.** Berkeley SoftFloat 3 is
branch-heavy C with rounding-mode state, exception flags, and a `softfloat_raiseFlags` global —
all of which must be stripped for a branchless, stateless target. The current code already
*follows* Berkeley's conventions where it matters (`_shiftRightJam128` is a faithful port,
`softfloat_common.jl:355-372`; the FMA scaling is Berkeley's `<<10/<<9`). Porting more of it
buys little. musl/AOR is different: it is already the source of truth for exp/log/pow/sin/cos,
and v2 should keep tracking it — but as *coefficient tables + algorithm spec*, not as
transliterated C.

**Compiling `Base.Math` straight through the pipeline is the more interesting question, and
it is the strategically right long-term answer.** The prize is enormous: no soft-float library
at all, `Base.exp` compiles like any other Julia function, and bit-exactness vs Julia becomes
tautological instead of a maintenance treadmill. What blocks it *today*:

1. **Hardware float instructions.** `Base.exp` lowers to `fmul double`, `fadd double`,
   `llvm.fma.f64`. The lowering has no gate-level implementation of these — that is precisely
   what soft-float exists to provide. **This is not actually a blocker: it is an argument for
   restructuring rather than eliminating.** If `lower.jl` gained handlers for
   `fadd/fsub/fmul/fdiv/fsqrt/fcmp/fptosi/...` on f64 that *emit the soft-float circuit
   directly* (rather than requiring the source to have been written in terms of `soft_*`
   calls), then arbitrary Julia float code compiles, and the soft-float library shrinks to
   tier A+B only — six arithmetic kernels plus conversions/comparisons, ~1,500 LOC total.
   Tiers C/D/E disappear entirely. **This is the single highest-leverage architectural
   change available in this area.**
2. **Control flow.** `Base.exp` is branchy (`if x > MAX; ...`), and `Base.pow_body` has a
   data-dependent loop. Compiling it needs the phi resolver to be trustworthy on diamond CFGs —
   the known correctness risk (CLAUDE.md). This is the *real* blocker, and it is in area C2/C3,
   not here. Note the irony: the soft-float library's branchless style exists to avoid the phi
   resolver, and the branchless style is what forces the library to exist.
3. **Julia-internal machinery in the call path.** `Base.exp` reaches `Base.Math.exp_impl`
   through `@inline`/`Val`/`getfield` on a table tuple; the extractor's const-global handling
   already copes with the tuple (`_extract_const_globals`), and the existing `_julia` ports
   prove the *body* extracts cleanly once the float ops are handled. So (3) is mostly solved.
4. **Error paths.** `Base.log(-1.0)` throws a `DomainError`; the wrapper compiles to a throw
   body and dies at the "VoidType wall". Needs a policy (IEEE NaN instead of throw) applied at
   extraction, which `soft_pow_julia` already improvises (`fpow_julia.jl:492-497`).

Verdict: **v2 should move float-op lowering into the compiler and keep only the arithmetic
kernels as a library.** Whether tier-C transcendentals are then Julia-compiled (best) or
generated from a kernel framework (§5a, the safe fallback) can be decided by how much the phi
resolver is trusted. Design v2's soft-float so both routes are open: the framework in §5a
should emit the *same* kernels that the float-op lowering uses.

### (c) Bit-exactness test conventions that MUST be carried over

These encode specific, expensive bug classes. Port them before porting any implementation.

1. **Raw-bit uniform fuzz over the full `UInt64` space** — `test_9x75_softfloat_raw_bits_sweep.jl`.
   `reinterpret(Float64, rand(UInt64))` gives every bit pattern equal probability, so
   subnormals, NaNs and extreme exponents are hit. Its header states the rationale explicitly:
   the `randn()*2^k` and `[-100,100]` sweeps let the soft_exp garbage bug (wigl) and the
   subnormal-divisor bug (r6e3) through. **Non-negotiable for every op, in every rewrite.**
2. **Subnormal-*output* sweeps for every transcendental** — CLAUDE.md §13; reference impls
   `test_softfexp.jl:135-170` and `:266-306`. Step finely enough (0.25–0.5) to populate every
   binade in the range where `Base.f(x)` is subnormal, assert bit-exact or ≤1 ULP. This caught
   the class where the exponent-field integer trick overflows into the sign bit.
3. **Strict bit equality, never `isnan()` fallbacks** — `test_m63k_softfloat_strict_bits.jl:24-28`
   documents why: the `if isnan(expected) … else bits==bits` pattern masks NaN-payload
   regressions.
4. **A fixed NaN-pattern battery** — `test_m63k_*.jl:32-39`: ±canonical qNaN, ±custom payload,
   sNaN with quiet-bit clear, as both LHS and RHS of every binary op. Pins the
   sign/payload/quieting policy.
5. **Invalid-op → hardware `INDEF` (`0xFFF8…`)** pinned explicitly (`test_m63k_*.jl:100-116`):
   `Inf−Inf`, `Inf+(−Inf)`, `Inf*0`, `0/0`, `Inf/Inf`, `sqrt(−1)`.
6. **Cross-op algebraic identities without an oracle** — `fma(a,b,0) ≡ fmul(a,b)` bit-exactly
   (`test_m63k_*.jl:118-134`). Detects asymmetric drift between two implementations of the
   same rounding.
7. **`ccall` to system libm as oracle where Julia would throw** — `sqrt(<0)`
   (`test_9x75_*.jl:88`), and the same trick for `sin`/`cos` bit-exactness vs libm.
8. **Boundary-triple tests at every threshold**: last input on each side plus the threshold
   itself (`test_softfexp.jl:289-314` — the overflow boundary at `709.7827128933841` /
   `709.79`, the underflow boundary at `−745.1332191019411` / `…413`). Every threshold constant
   in the library should have this triple.
9. **Both-sided statistical bounds on ULP-drift rates.** `worklog/046:167` records the reason:
   asserting `0.001 < rate < 0.02` catches *accidental improvement* (someone silently changed
   the algorithm across the musl/Base boundary) as well as regression.
10. **Fast/exact variant agreement outside the documented divergence range**
    (`test_softfexp.jl:172-186`), so the cost knob cannot silently change accuracy elsewhere.
11. **Dispatch-plumbing bit-identity tests** — `test_l5v8_*.jl:59-68`: every sugar overload must
    be *bit-identical* to the primitive it forwards to, tested over random + special inputs.
    Cheap and it catches the whole class of "wired to the wrong variant".

Add one convention v1 lacks: **a test that asserts the generated LLVM IR for each soft-float
function contains no `br` instructions** (except the deliberately branchy `pow_julia`
family). The branchless invariant is the library's core contract and nothing currently checks it.

### (d) The f32 double-rounding gap and the `SoftFloat` sugar type

**The f32 gap.** Correctly diagnosed and honestly documented (`fpconv.jl:18-37`): f32
arithmetic is routed `soft_fpext → f64 op → soft_fptrunc`, which double-rounds and is *not*
bit-exact vs hardware f32. `reversible_compile(f, Float32)` is rejected outright, so the
exposure is limited to mixed-precision IR arriving via a Float64 entry point. Assessment:

- The containment (reject f32 entry) is the right call and should be kept in v2.
- The claim "≤1 ulp double-rounding deviation in the worst case" is the *usual* bound, but
  double rounding f64→f32 can be wrong in the classic sticky-bit-annihilation cases; there is
  no test that bounds it. If v2 keeps the routing, add a fuzz test asserting the deviation
  bound rather than asserting it in a docstring.
- **In v2 this should not exist at all.** Once `unpack`/`pack_round` are parameterised on
  `(exp_bits, mant_bits)` (§4.3 Layer 0), f32 is a *type parameter*, not a separate
  implementation: `soft_fadd(::Binary32, a, b)` is the same generated kernel with different
  widths. That is a few hours of framework work and it deletes both the gap and the rejection.
  It also opens bf16/f16, which matter if this ever targets ML workloads.
- Note the gap is wider than documented: `soft_fpext` takes `UInt32` and `soft_fptrunc`
  returns `UInt32`, i.e. f32 values live in 32-bit wires — but there are no f32 comparison,
  conversion, min/max, or transcendental primitives at all, so any f32 code path beyond the
  four arithmetic ops has undefined behaviour rather than approximate behaviour.

**The `SoftFloat` sugar type.** Assessment: the *idea* is right, the *implementation* is a
thin, incomplete, and dangerously silent shim.

- It is the sole mechanism by which `reversible_compile(f, Float64)` works: the wrapper
  `x -> (@inline f(SoftFloat(x))).bits` (`softfloat_dispatch.jl:131`) forces Julia to inline
  through the operator overloads so the IR contains direct `soft_*` calls. Clever, and it
  works.
- **The failure mode for a missing method is terrible.** If a user function calls anything not
  overloaded, Julia compiles the wrapper body to `jl_f_throw_methoderror` + `unreachable` with
  a `void` return, and extraction dies at the "VoidType wall" with an error that names neither
  the missing method nor the offending call. This is documented as the exact history of
  Bennett-l5v8 (`softfloat_dispatch.jl:53-58`, `test_l5v8_*.jl:1-9`) — 18 transcendental
  overloads were simply absent and `reversible_compile(sin, Float64)` failed cryptically.
- **The surface is still incomplete, and the same trap is still armed.** Present: `+ - * /`,
  `<`, `==`, `copysign`, `abs`, `floor/ceil/trunc/round`, `sqrt`, `exp/exp2`, `min/max`,
  `^(SoftFloat,SoftFloat)`, and 18 transcendentals. **Absent:** `<=`, `>`, `>=`, `!=`,
  `isless`, `isnan`, `isinf`, `isfinite`, `zero`, `one`, `promote_rule`, `convert`, `muladd`,
  `fma`, `inv`, `abs2`, `sign`, `flipsign`, `ldexp`, `hypot`, `cbrt`, `^(::SoftFloat,
  ::Integer)`. That last one means a literal `x^2` in user code — completely ordinary Julia —
  hits the VoidType wall. Missing `zero`/`one`/`promote_rule` means `sum`, `prod`, and most
  generic numeric code fails the same way.
- `SoftFloat` is not `<: Real` (`softfloat_dispatch.jl:11`), which is why generic fallbacks
  don't rescue it; but subtyping `Real` without `promote_rule` would create ambiguity with the
  `::Real` mixed-arity methods at lines 22-29. The type needs a proper number-interface
  implementation, not more one-off methods.

**v2 recommendation for the sugar:** (i) make the wrapper detect a `throw`-only body and
report *which* method is missing — a five-line check that converts the worst error message in
the system into a good one; (ii) implement the full `AbstractFloat`/`Real` interface once,
with `promote_rule`, so generic Julia code works by default; (iii) better still, make the
sugar unnecessary by lowering hardware float ops directly (§5b) and keep `SoftFloat` only as a
debugging/reference oracle that runs the same kernels in the host.

---

## 6. One-paragraph verdict

The soft-float library is the highest-quality *numerics* in the repository and the
lowest-quality *software* in it. The algorithms, the special-case policy, and above all the
test conventions are worth carrying over almost verbatim; the 8,179 lines of one-file-per-op,
32 duplicated classify preambles, four copies of the exp kernel, three transcribed log tables,
dead code in the hottest function, silent const shadowing, and source contorted to dodge the
SLP vectorizer are all disposable. A v2 built on (i) width-parameterised
`unpack`/`pack_round`, (ii) a branchless-combinator macro that *enforces* the no-`br`
invariant, (iii) a table-driven transcendental generator, and (iv) float-op lowering moved
into the compiler so that `Base.Math` can eventually be compiled directly — would be roughly
a quarter of the size, cover f32/f16 for free, shed the Julia-1.12-internals coupling, and be
strictly more capable. The two prerequisites live outside this area: a phi resolver that can
be trusted with real control flow, and a reversible call/uncall so a `soft_fmul` isn't 149k
gates *per call site*.
