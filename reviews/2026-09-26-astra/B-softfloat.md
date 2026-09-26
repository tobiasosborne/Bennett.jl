# Astra review — B-softfloat — 2026-09-26
Status: IN PROGRESS
Scope: `src/softfloat/`, `src/softfloat_dispatch.jl`, Float64 `reversible_compile` in `src/Bennett.jl`, and relevant tests/lowering paths.
Method: Read `CLAUDE.md` in full. Read-only source review and targeted Julia probes with bounds checking; no full suite, issue mutations, or source changes. The review-specific one-file restriction overrides the worklog and session-close mutation rules.

## Executive summary
Pending completion.

## Findings

### F1 — [S0] Large finite arguments produce completely wrong sine, cosine, and tangent
- Where: `src/softfloat/fsin.jl:114` (`_RP_INV_2PI[12]`), consumed at `fsin.jl:495–497` by Payne–Hanek reduction; `src/softfloat/ftan.jl`; public dispatch `src/softfloat_dispatch.jl:58–60`.
- Evidence: VERIFIED-BY-EXECUTION. Julia 1.12.3, bounds checking enabled. `soft_sin(0x6dfd3af758367500)` returned `0xbfd65997f31adcad`; `reinterpret(UInt64, sin(reinterpret(Float64, 0x6dfd3af758367500)))` returned `0x3f3672d0d39a6e33`. `soft_cos(0x7096a3fc1ff6c559)` returned `0x3f31a151f3a4fff6`, reference `0xbfefa47c72347349`. `soft_tan(0x72e7a7b800919a08)` returned `0x3f6391785d15165c`, reference `0xc07a2a3324e0624b`. These are wrong signs/magnitudes, not permitted 1–2 ULP drift.
- Failure scenario: valid large finite Float64 inputs silently return unrelated trigonometric values through both primitives and the new public overloads. A seed-`0xb527` sweep (100,000 candidates/function, alternating raw UInt64 inputs and broad finite arguments) found 9,615/9,578/9,667 cases exceeding 2 ULP for sin/cos/tan respectively.
- Root cause: limb 12 is `0xc7fe25ffff781660`; computing the expansion of `1/(2π)` at 2,048-bit BigFloat precision gives `0xc7fe25fff7816603`. All other 18 limbs match. The comment “cross-checked vs Julia table” is false for the actual literal.
- Fix: correct that literal to `0xc7fe25fff7816603`; add an independently generated high-precision check of the complete table and revalidate all three consumers. The existing random trig tests stop at approximately `1e22`, far below the affected table windows.
- Fix validation: loaded an independent module from the existing source strings with only that literal corrected (no files changed). Seed `0xb529`, 100,000 raw-bit candidates per operation: zero cases above 2 ULP; maxima were sin=1, cos=0, tan=1 ULP.
- Test: pin the three exact bit witnesses above; use raw-bit positive and negative finite inputs across all 2,046 exponent fields and targeted multiples of π/2, instead of only moderate magnitudes.
- Already tracked? No matching numerical-failure bead found. Bennett-l5v8 (closed) correctly describes adding dispatch overloads, but its successful limited-range validation does not establish full-range numerical correctness.

### F2 — [S0] Mixed SoftFloat equality silently returns false and miscompiles numeric branches
- Where: `src/softfloat_dispatch.jl:11`, `:30–31`, `:136`; only `==(SoftFloat, SoftFloat)` exists, while `SoftFloat` is not a `Number`.
- Evidence: VERIFIED-BY-EXECUTION. `Bennett.SoftFloat(0.0) == 0.0` prints `false`. `f(x)=ifelse(x==0.0,-x,x); c=reversible_compile(f,Float64)` compiles to 66 gates. `simulate(c,UInt64(0))` returns `0x0000000000000000`; native `reinterpret(UInt64,f(0.0))` is `0x8000000000000000`. `verify_reversibility(c;n_tests=10)` returns `true`. This is a semantic mismatch, not an ancilla failure.
- Failure scenario: a generic Float64 function comparing its input with a literal invokes Base's heterogeneous equality fallback on the wrapper, allowing Julia to fold the branch to false. The wrapper changes numeric semantics before LLVM extraction.
- Fix: provide mixed `==` methods in both argument orders with semantics matching Float64 comparisons, including Julia's exact Float64/Integer comparison behavior; do not blindly round large integers before comparison. Provide `isequal` consistently if the wrapper is intended for generic numeric code, or reject unsupported heterogeneous predicates before compiling.
- Test: compile branches guarded by `x==0.0`, `0.0==x`, `x==0`, and `x!=1`; verify exact outputs for ±0, normal values, NaN, and integer boundaries beyond 2^53, plus ancilla cleanup.
- Already tracked? No matching bead found.

### F3 — [S0] Public min/max discard NaN sign, payload, and signaling state
- Where: `src/softfloat/fmin.jl:48`, `:76`; `src/softfloat_dispatch.jl:46–47`; `test/test_k2w6_soft_fminmax.jl`.
- Evidence: VERIFIED-BY-EXECUTION. Seed `0xb528`, 200,000 raw-bit pairs per min/max produced 186 mismatches each, all encountered on NaNs. For `soft_fminimum(0x7ffdb067bde7cfb5,0x65c861318a293c31)`, actual=`0x7ff8000000000000`, Base.min=`0x7ffdb067bde7cfb5`. For `soft_fmaximum(0xee7f52a0153989e7,0xfff370da26cf0889)`, actual=`0x7ff8000000000000`, Base.max=`0xfff370da26cf0889`.
- Failure scenario: accepted NaN input becomes canonical positive qNaN; Julia's min/max preserve the selected NaN bit pattern, including signaling state in the observed runtime. This violates the public Float64 bit contract and the source's “matches Base.min/max bit-exactly” claim.
- Fix: implement the Julia-facing NaN selection rule without canonicalization; keep a separate LLVM-facing policy if required. Do not reuse the arithmetic `| QUIET_BIT` helper without checking Julia's min/max behavior.
- Test: strict UInt64 comparisons over a Cartesian matrix of distinct positive/negative qNaNs and sNaNs, finite values, infinities, and signed zeros; test the compiled public overload and reversibility.
- Already tracked? Bennett-k2w6 is closed and claims bit-exact Base.min/max behavior. Its NaN-propagation intent is correct, but its bit-exact completion claim is false for noncanonical NaNs. Bennett-r84x's older canonicalization repair does not cover this newer implementation.

### F4 — [S1] Common valid Float64 expressions still hit the missing-dispatch wall
- Where: `src/softfloat_dispatch.jl:15–75`, wrapper at `:136`.
- Evidence: VERIFIED-BY-EXECUTION. `reversible_compile(x->x^2,Float64)`, `reversible_compile(x->fma(x,x,x),Float64)`, and `reversible_compile(x->ifelse(x<0.0,-x,x),Float64)` each throw `ir_extract.jl: VoidType reached _type_width ... (Bennett-dq8l / U81)`. Direct evaluation with `SoftFloat(0.0)` produces MethodError for literal powers, fma, mixed `<`, `isnan`, `isfinite`, and mixed min. `^` only supports two SoftFloat arguments; the existing `soft_fma` has no Base.fma forwarder.
- Failure scenario: ordinary generic Float64 kernels cannot compile despite the underlying arithmetic primitives being implemented. The error misdiagnoses an unsupported wrapper operation as an extractor void-width problem.
- Fix: add the missing numeric dispatch methods, including `literal_pow`/integer power semantics, mixed comparisons, and FMA; reject any remaining unsupported wrapper operation at the API boundary with the original method context. Explicitly define the supported generic Float64 subset.
- Test: compile `x^2`, positive/zero/negative literal powers, `fma`, mixed comparisons in both orders, and finite/NaN predicates with Float64 outputs; compare output bits and ancilla state.
- Already tracked? Bennett-l5v8 correctly fixed the same cause for 18 transcendental overloads but did not cover these operations. No matching open bead found; Bennett-h6f covers LLVM FMA lowering, not the missing public dispatch.

### F5 — [S0] soft_pow returns +1 for every exponent of −1, including odd integers
- Where: `src/softfloat/fpow.jl:696`, `:734`, `:923`; `test/test_softfpow.jl:85–89`.
- Evidence: VERIFIED-BY-EXECUTION. `soft_pow(0xbff0000000000000,0x3ff0000000000000)` returns `0x3ff0000000000000`; native/libm `(-1.0)^1.0` is `0xbff0000000000000`. The same wrong positive result occurs for exponents `3.0` and `-3.0`. For exponent `0.5`, it returns +1 instead of libm's `0xfff8000000000000`; for canonical NaN exponent it returns +1 instead of `0x7ff8000000000000`.
- Failure scenario: `abs_x_is_one` is an unconditional highest-priority override, erasing the odd-integer sign, noninteger-domain NaN, and NaN propagation. This affects the exported musl primitive and the `llvm.pow.f64` ingest route; the Julia-specific primitive correctly avoids this particular error.
- Fix: unconditional +1 applies to **positive** one, and to either sign of one only when the exponent is infinite (plus the already separate zero-exponent rule). Let negative one with finite odd/even/noninteger exponents follow the ordinary sign/domain logic. Correct the false “pow(±1,y)=1 always” docstring and test oracle.
- Test: compare both signs of one with odd/even positive/negative integers, ±0, fractions, ±Inf, and distinct NaNs against a real oracle. The current test explicitly asserts the wrong result for −1, rather than detecting it.
- Already tracked? No matching bug bead found. Bennett-jexo correctly introduced a distinct Julia path, but the retained musl path is not a faithful port for these inputs.

### F6 — [S1] The Julia power overload cannot compile because its integer helper is unregistered
- Where: `src/softfloat/fpow_julia.jl:388`, `:473–474`; `src/callees.jl:68–79`; `src/softfloat_dispatch.jl:52`.
- Evidence: VERIFIED-BY-EXECUTION. Both `Bennett.extract_parsed_ir(soft_pow_julia,Tuple{UInt64,UInt64})` and `reversible_compile(^,Float64,Float64)` fail with `call to j__pj_pow_body_int_... has no registered callee handler or intrinsic pattern` (Bennett-5oyt/U15).
- Failure scenario: this is not the missing mixed-power overload in F4: **two actual Float64 arguments** reach the correct SoftFloat method, then fail extraction. The `while n>1` helper survives Julia optimization as a call and is absent from the callee registry.
- Fix: make the helper reachable through a correctly typed registered/inlined path; preserve its signed exponent ABI and explicit maximum of 15 squaring iterations. Then run complete circuit tests for integer and noninteger exponents, since admitting the helper exposes its branching/loop behavior to lowering.
- Test: add `reversible_compile(^,Float64,Float64)` with integer exponents (negative, 0, 1, 3, −4096, 24576), a fractional exponent, zero/Inf/NaN, reference outputs, and ancilla checks. The current `test_softfpow_julia.jl` only calls the host primitive and contains no circuit compilation.
- Already tracked? Bennett-jexo is closed and correctly reports library numerical tests; its dispatch wiring does not deliver a compilable power operation. No open bead for this missing helper found.

### F7 — [S1] The Float64 wrapper rejects even a constant Float64 return
- Where: `src/softfloat_dispatch.jl:136`, `:142`, `:148` (unconditional `.bits` on the function result).
- Evidence: VERIFIED-BY-EXECUTION. `reversible_compile(x->1.0,Float64)` fails with `VoidType reached _type_width`; so do `reversible_compile(x->x==x,Float64)` and `reversible_compile(x->Int64(x),Float64)`.
- Failure scenario: a function can accept the wrapper but return a perfectly ordinary Float64 constant, which has no `.bits` property. Predicate outputs also fail despite valid comparison dispatch. Integer-returning functions additionally need conversion methods; the wrapper currently has neither output adaptation nor a useful diagnostic.
- Fix: adapt outputs by type (SoftFloat → bits, ordinary Float64 → reinterpret, supported integers/Bool → their values), and validate unsupported result types explicitly before extraction. Add conversion dispatch separately where needed.
- Test: compile a constant Float64, a Boolean equality predicate, and an in-range Float64-to-integer conversion, including multiargument variants; check outputs and ancilla cleanup.
- Already tracked? Bennett-777 (closed) explicitly identifies the SoftFloat-result assumption, but its closure reports that `soft_fptosi` exists rather than repairing this API path. The original tracked diagnosis remains correct; the completion claim does not hold for this overload.

### F8 — [S0] exp/exp2 form an infinite scale before the true result overflows
- Where: `src/softfloat/fexp.jl:323–325`, `:428–430`; duplicated fast paths `:516–517`, `:593–594`; dependent transcendental callers under investigation.
- Evidence: VERIFIED-BY-EXECUTION. `soft_exp(0x40862e4189374bc7)` (`x=709.782`) gives `0xfff8000000000000` (NaN), versus Base.exp `0x7feffa297cab7a93` (finite). `soft_exp(0x40862e42fefa39ef)` gives NaN versus `0x7fefffffffffff2a`. `soft_exp2(0x408ffff9db22d0e5)` (`x=1023.997`) gives NaN versus `0x7fefeefba041287f`; at `prevfloat(1024.0)` (`0x408fffffffffffff`) it gives NaN versus `0x7feffffffffffd3a`.
- Failure scenario: range reduction rounds the scale exponent up to 1024 while a negative residual keeps the actual exponential finite. The code encodes the scale as +Inf, then evaluates `Inf + Inf*negative`, producing an invalid NaN. There is an underflow reconstruction helper but no corresponding overflow reconstruction below the hard overflow cutoff.
- Fix: port the high-exponent reconstruction from the reference algorithm: temporarily lower the scale exponent, reconstruct the residual-adjusted value while finite, then multiply by an exact power of two. Share this path with both fast variants; FTZ does not authorize overflow-region NaNs.
- Test: fine sweeps through the top exponential reduction cell and exact predecessor/successor tests at `log(floatmax(Float64))` / 1024; assert non-NaN and ≤1 ULP for finite references. Include all consumers of exp_fast.
- Already tracked? No matching open bead found. This is distinct from the Bennett-wigl underflow bug; the repaired subnormal path does not cover the high-exponent problem.

## Unconfirmed suspicions


## What is sound (brief)
- Julia 1.12.3, `--startup-file=no --project --check-bounds=yes`: seed `0xb526`, 300,000 independent raw-bit samples per operation gave **zero mismatches** for add, subtract, multiply, divide, square root, and FMA (1.8 million comparisons). Square root used `ccall(:sqrt, ...)` to include negative-domain IEEE results. This does not establish exhaustive correctness.
- Core arithmetic pre-normalizes subnormals and carries guard/round/sticky bits through final packing. FMA preserves a full 128-bit product, including the low-limb fold after catastrophic cancellation.
- Seed `0xb528`: 200,000 raw inputs each for sitofp, fpext, fptrunc, fptosi, and fptoui passed their native/unsafe-trunc oracle; another 200,000 each for floor, ceil, trunc, ties-even round, and ties-away round passed. Checked Float32 compile is rejected with an explicit ArgumentError.
- Seed `0xb527`: 100,000 candidates per unary transcendental, alternating raw bits and function-specific finite ranges. Within the valid real domain, exp/exp2/log/log2/log10/atan/asin/acos/sinh/cosh/tanh/asinh/acosh/atanh/log1p/expm1 stayed within 2 ULP; exp_julia/exp2_julia had zero bit mismatches. Domain-filtered candidate counts vary. Trig failures are F1.

## Nits (S4)

## Coverage log
- Read `CLAUDE.md` in full.
- Read all of `softfloat_dispatch.jl`, `softfloat.jl`, `fadd.jl`, `fsub.jl`, `fmul.jl`, `fma.jl`, `fneg.jl`, `sitofp.jl`, `fptosi.jl`, `fptoui.jl`; common helper implementations; strict-bit and raw-bit test structure; C4 architecture review through its first findings. Core random sweep completed.
- Read `fdiv.jl`, `fsqrt.jl`, `fpconv.jl`, `fround.jl`, `fcmp.jl`, `fmin.jl`, trig table and reduction dispatch, and l5v8 dispatch tests. Completed conversion/rounding/min-max and unary transcendental probes. Confirmed F1's fix in an isolated in-memory module; repository code remains untouched.
