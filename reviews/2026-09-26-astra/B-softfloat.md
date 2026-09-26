# Astra review — B-softfloat — 2026-09-26
Status: COMPLETE
Scope: `src/softfloat/`, `src/softfloat_dispatch.jl`, Float64 `reversible_compile` in `src/Bennett.jl`, and relevant tests/lowering paths.
Method: Read `CLAUDE.md` in full. Read-only source review and targeted Julia probes with bounds checking; no full suite, issue mutations, or source changes. The review-specific one-file restriction overrides the worklog and session-close mutation rules.

## Executive summary

**11 confirmed findings: six S0, three S1, two S2; all verified by execution.**
A mistyped reduction-table limb corrupts large-argument sin/cos/tan; correcting it in memory eliminated the sampled failures.
Exp overflow reconstruction is missing and propagates NaNs into expm1/sinh/cosh; the recorded workaround is incomplete.
Other silent errors affect negative-one powers, mixed equality, and NaN payloads; three public compilation paths remain broken.
Core arithmetic passed 1.8 million raw-bit comparisons; all 60 primitive IRs contain no native floating arithmetic, and QROM passed exhaustive lookup checks.
Existing exp/trig/pow test files remain green; power’s subnormal sweeps skip most binades, and its advertised native-accuracy bound is false.

## Findings

### F1 — [S0] Large finite arguments produce completely wrong sine, cosine, and tangent

- Where: `src/softfloat/fsin.jl:114` (`_RP_INV_2PI[12]`), consumed at `fsin.jl:495–497` by Payne–Hanek reduction; `src/softfloat/ftan.jl`; public dispatch `src/softfloat_dispatch.jl:58–60`.
- Evidence: VERIFIED-BY-EXECUTION. Julia 1.12.3, bounds checking enabled. `soft_sin(0x6dfd3af758367500)` returned `0xbfd65997f31adcad`; `reinterpret(UInt64, sin(reinterpret(Float64, 0x6dfd3af758367500)))` returned `0x3f3672d0d39a6e33`. `soft_cos(0x7096a3fc1ff6c559)` returned `0x3f31a151f3a4fff6`, reference `0xbfefa47c72347349`. `soft_tan(0x72e7a7b800919a08)` returned `0x3f6391785d15165c`, reference `0xc07a2a3324e0624b`. These are wrong signs/magnitudes, not permitted 1–2 ULP drift.
- Failure scenario: valid large finite Float64 inputs silently return unrelated trigonometric values through both primitives and the new public overloads. A seed-`0xb527` sweep (100,000 candidates/function, alternating raw UInt64 inputs and broad finite arguments) found 9,615/9,578/9,667 cases exceeding 2 ULP for sin/cos/tan respectively.
- Root cause: limb 12 is `0xc7fe25ffff781660`; computing the expansion of `1/(2π)` at 2,048-bit BigFloat precision gives `0xc7fe25fff7816603`. All other 18 limbs match. The comment “cross-checked vs Julia table” is false for the actual literal.
- Fix: correct that literal to `0xc7fe25fff7816603`; add an independently generated high-precision check of the complete table and revalidate all three consumers. The existing random trig tests stop at approximately `1e22`, far below the affected table windows.
- Fix validation: loaded an independent module from the existing source strings with only that literal corrected (no files changed). Seed `0xb529`, 100,000 raw-bit candidates per operation: zero cases above 2 ULP; maxima were sin=1, cos=0, tan=1 ULP.
- Test: pin the three exact bit witnesses above; use raw-bit positive and negative finite inputs across all 2,047 finite exponent fields and targeted multiples of π/2, instead of only moderate magnitudes.
- Already tracked? No matching numerical-failure bead found. Bennett-l5v8 (closed) correctly describes adding dispatch overloads, but its successful limited-range validation does not establish full-range numerical correctness.

### F8 — [S0] exp/exp2 form an infinite scale before the true result overflows

- Where: `src/softfloat/fexp.jl:323–325`, `:428–430`; duplicated fast paths; `src/softfloat/fexpm1.jl:136`, `src/softfloat/fsinh.jl:202`, `src/softfloat/fcosh.jl:149`.
- Evidence: VERIFIED-BY-EXECUTION. `soft_exp(0x40862e4189374bc7)` (`x=709.782`) gives `0xfff8000000000000` (NaN), versus Base.exp `0x7feffa297cab7a93` (finite). `soft_exp(0x40862e42fefa39ef)` gives NaN versus `0x7fefffffffffff2a`. `soft_exp2(0x408ffff9db22d0e5)` (`x=1023.997`) gives NaN versus `0x7fefeefba041287f`; at `prevfloat(1024.0)` (`0x408fffffffffffff`) it gives NaN versus `0x7feffffffffffd3a`.
- Propagation (VERIFIED-BY-EXECUTION): `soft_expm1(0x40862e4189374bc7)` also gives `0xfff8000000000000` instead of `0x7feffa297cab7a93`. At ±1419.564 (bits `0x40962e4189374bc7` / `0xc0962e4189374bc7`), `soft_sinh` and `soft_cosh` return `0xfff8000000000000`; native sinh is ±Inf and cosh is +Inf. Their `exp(abs(x)/2)` call encounters the same bad scale cell. These functions are directly exposed by the new SoftFloat overloads.
- Failure scenario: range reduction rounds the scale exponent up to 1024 while a negative residual keeps the actual exponential finite. The code encodes the scale as +Inf, then evaluates `Inf + Inf*negative`, producing an invalid NaN. There is an underflow reconstruction helper but no corresponding overflow reconstruction below the hard overflow cutoff.
- Fix: move/reuse the existing `_pow_exp_specialcase_overflow` (`fpow.jl:569–574`) in the exp family: temporarily lower the scale exponent, reconstruct the residual-adjusted value while finite, then multiply by an exact power of two. Share this path with both fast variants; FTZ does not authorize overflow-region NaNs.
- Test: fine sweeps through the top exponential reduction cell and exact predecessor/successor tests at `log(floatmax(Float64))` / 1024; assert non-NaN and ≤1 ULP for finite references. Include all consumers of exp_fast.
- Already tracked? **Bennett-ky5n (closed) explicitly records the exp_fast NaN bug** in its close reason; `fsinh.jl:112–120` and `fcosh.jl:45–50` retain the workaround rationale. The root diagnosis is right, but the workaround only protects the medium arm: the huge arm re-enters the bad interval at doubled input. Its claim that sinh/cosh remain finite to ≈1419 is also false (true overflow is near 710.476). No dedicated open repair bead was found. This is distinct from Bennett-wigl’s repaired underflow bug.

### F5 — [S0] soft_pow returns +1 for every exponent of −1, including odd integers

- Where: `src/softfloat/fpow.jl:696`, `:744`, `:923`; `test/test_softfpow.jl:85–89`.
- Evidence: VERIFIED-BY-EXECUTION. `soft_pow(0xbff0000000000000,0x3ff0000000000000)` returns `0x3ff0000000000000`; native/libm `(-1.0)^1.0` is `0xbff0000000000000`. The same wrong positive result occurs for exponents `3.0` and `-3.0`. For exponent `0.5`, it returns +1 instead of libm's `0xfff8000000000000`; for canonical NaN exponent it returns +1 instead of `0x7ff8000000000000`.
- Failure scenario: `abs_x_is_one` is an unconditional highest-priority override, erasing the odd-integer sign, noninteger-domain NaN, and NaN propagation. This affects the exported musl primitive and the `llvm.pow.f64` ingest route; the Julia-specific primitive correctly avoids this particular error.
- Fix: unconditional +1 applies to **positive** one, and to either sign of one only when the exponent is infinite (plus the already separate zero-exponent rule). Let negative one with finite odd/even/noninteger exponents follow the ordinary sign/domain logic. Correct the false “pow(±1,y)=1 always” docstring and test oracle.
- Test: compare both signs of one with odd/even positive/negative integers, ±0, fractions, ±Inf, and distinct NaNs against a real oracle. The current test explicitly asserts the wrong result for −1, rather than detecting it.
- Already tracked? No matching bug bead found. Bennett-jexo correctly introduced a distinct Julia path, but the retained musl path is not a faithful port for these inputs.

### F2 — [S0] Mixed SoftFloat equality silently returns false and miscompiles numeric branches

- Where: `src/softfloat_dispatch.jl:11`, `:30–31`, `:136`; only `==(SoftFloat, SoftFloat)` exists, while `SoftFloat` is not a `Number`.
- Evidence: VERIFIED-BY-EXECUTION. `Bennett.SoftFloat(0.0) == 0.0` prints `false`. `f(x)=ifelse(x==0.0,-x,x); c=reversible_compile(f,Float64)` compiles to 66 gates. `simulate(c,UInt64(0))` returns `0x0000000000000000`; native `reinterpret(UInt64,f(0.0))` is `0x8000000000000000`. `verify_reversibility(c;n_tests=10)` returns `true`. This is a semantic mismatch, not an ancilla failure.
- Failure scenario: a generic Float64 function comparing its input with a literal invokes Base's heterogeneous equality fallback on the wrapper, allowing Julia to fold the branch to false. The wrapper changes numeric semantics before LLVM extraction.
- Fix: provide mixed `==` methods in both argument orders with semantics matching Float64 comparisons, including Julia's exact Float64/Integer comparison behavior; do not blindly round large integers before comparison. Provide `isequal` consistently if the wrapper is intended for generic numeric code, or reject unsupported heterogeneous predicates before compiling.
- Test: compile branches guarded by `x==0.0`, `0.0==x`, `x==0`, and `x!=1`; verify exact outputs for ±0, normal values, NaN, and integer boundaries beyond 2^53, plus ancilla cleanup.
- Already tracked? No matching bead found.

### F3 — [S0] Public min/max discard NaN sign, payload, and signaling state

- Where: `src/softfloat/fmin.jl:47`, `:75`; `src/softfloat_dispatch.jl:46–47`; `test/test_k2w6_soft_fminmax.jl`.
- Evidence: VERIFIED-BY-EXECUTION. Seed `0xb528`, 200,000 raw-bit pairs per min/max produced 186 mismatches each, all encountered on NaNs. For `soft_fminimum(0x7ffdb067bde7cfb5,0x65c861318a293c31)`, actual=`0x7ff8000000000000`, Base.min=`0x7ffdb067bde7cfb5`. For `soft_fmaximum(0xee7f52a0153989e7,0xfff370da26cf0889)`, actual=`0x7ff8000000000000`, Base.max=`0xfff370da26cf0889`.
- Circuit confirmation: `reversible_compile(min,Float64,Float64)` maps `(0xfff8000000000123, reinterpret(UInt64,1.0))` to `0x7ff8000000000000`, versus native `0xfff8000000000123`; `verify_reversibility(c;n_tests=20)` returns true.
- Failure scenario: accepted NaN input becomes canonical positive qNaN; Julia's min/max preserve the selected NaN bit pattern, including signaling state in the observed runtime. This violates the public Float64 bit contract and the source's “matches Base.min/max bit-exactly” claim.
- Fix: implement the Julia-facing NaN selection rule without canonicalization; keep a separate LLVM-facing policy if required. Do not reuse the arithmetic `| QUIET_BIT` helper without checking Julia's min/max behavior.
- Test: strict UInt64 comparisons over a Cartesian matrix of distinct positive/negative qNaNs and sNaNs, finite values, infinities, and signed zeros; test the compiled public overload and reversibility.
- Already tracked? Bennett-k2w6 is closed and claims bit-exact Base.min/max behavior. Its NaN-propagation intent is correct, but its bit-exact completion claim is false for noncanonical NaNs. Bennett-r84x's older canonicalization repair does not cover this newer implementation.

### F9 — [S0] Julia power loses negative-NaN payloads for fractional exponents

- Where: `src/softfloat/fpow_julia.jl:487–493`, before its nonfinite-base handling at `:498–507`; `test/test_softfpow_julia.jl:33–34`.
- Evidence: VERIFIED-BY-EXECUTION. For `a=0xfff8000000000123`, `b=0xbfe0000000000000` (−0.5), `soft_pow_julia(a,b)` returns `0x7ff8000000000000`, while Julia `reinterpret(UInt64,reinterpret(Float64,a)^reinterpret(Float64,b))` returns `0x7ff8000000000123`. With signaling `a=0xfff0000000000123`, native returns `0x7ff0000000000123`, soft returns `0x7ff8000000000000`.
- Failure scenario: the code treats the sign bit of a negative NaN as a negative real domain violation and returns a canonical NaN before reaching the nonfinite-base path. Base preserves the payload under its own sign convention. The purported bit-exact test only checks `isnan` whenever the reference is NaN.
- Fix: classify NaN bases before the negative finite/domain rule and reproduce Julia's sign/payload handling and existing zero-exponent/positive-one priorities exactly. Keep the deliberate DomainError-to-NaN convention restricted to actual domain errors.
- Test: strict bit comparison on a Cartesian matrix of positive/negative qNaNs/sNaNs with integer, fractional, infinite, zero, and NaN exponents. Domain-error cases can use an explicitly documented NaN policy; existing native NaNs must not bypass equality.
- Already tracked? No matching open bead found. Bennett-jexo's broad bit-exact claim and Bennett-m63k's strict-NaN testing principle do not hold for this implementation/test.

### F6 — [S1] The Julia power overload cannot compile because its integer helper is unregistered

- Where: `src/softfloat/fpow_julia.jl:388`, `:473–474`; `src/callees.jl:68–79`; `src/softfloat_dispatch.jl:52`.
- Evidence: VERIFIED-BY-EXECUTION. Both `Bennett.extract_parsed_ir(soft_pow_julia,Tuple{UInt64,UInt64})` and `reversible_compile(^,Float64,Float64)` fail with `call to j__pj_pow_body_int_... has no registered callee handler or intrinsic pattern` (Bennett-5oyt/U15).
- Failure scenario: this is not the missing mixed-power overload in F4: **two actual Float64 arguments** reach the correct SoftFloat method, then fail extraction. The `while n>1` helper survives Julia optimization as a call and is absent from the callee registry.
- Fix: make the helper reachable through a correctly typed registered/inlined path; preserve its signed exponent ABI and explicit bound of 15 squaring iterations (the accepted exponent interval actually needs at most 14 loop bodies). Then run complete circuit tests for integer and noninteger exponents, since admitting the helper exposes its branching/loop behavior to lowering.
- Test: add `reversible_compile(^,Float64,Float64)` with integer exponents (negative, 0, 1, 3, −4096, 24576), a fractional exponent, zero/Inf/NaN, reference outputs, and ancilla checks. The current `test_softfpow_julia.jl` only calls the host primitive and contains no circuit compilation.
- Already tracked? Bennett-jexo is closed and correctly reports library numerical tests; its dispatch wiring does not deliver a compilable power operation. No open bead for this missing helper found.

### F4 — [S1] Common valid Float64 expressions still hit the missing-dispatch wall

- Where: `src/softfloat_dispatch.jl:15–75`, wrapper at `:136`.
- Evidence: VERIFIED-BY-EXECUTION. `reversible_compile(x->x^2,Float64)`, `reversible_compile(x->fma(x,x,x),Float64)`, and `reversible_compile(x->ifelse(x<0.0,-x,x),Float64)` each throw `ir_extract.jl: VoidType reached _type_width ... (Bennett-dq8l / U81)`. Direct evaluation with `SoftFloat(0.0)` produces MethodError for literal powers, fma, mixed `<`, `isnan`, `isfinite`, and mixed min. `^` only supports two SoftFloat arguments; the existing `soft_fma` has no Base.fma forwarder.
- Failure scenario: ordinary generic Float64 kernels cannot compile despite the underlying arithmetic primitives being implemented. The error misdiagnoses an unsupported wrapper operation as an extractor void-width problem.
- Fix: add the missing numeric dispatch methods, including `literal_pow`/integer power semantics, mixed comparisons, and FMA; reject any remaining unsupported wrapper operation at the API boundary with the original method context. Explicitly define the supported generic Float64 subset.
- Test: compile `x^2`, positive/zero/negative literal powers, `fma`, mixed comparisons in both orders, and finite/NaN predicates with Float64 outputs; compare output bits and ancilla state.
- Already tracked? Bennett-l5v8 correctly fixed the same cause for 18 transcendental overloads but did not cover these operations. No matching open bead found; Bennett-h6f covers LLVM FMA lowering, not the missing public dispatch.

### F7 — [S1] The Float64 wrapper rejects even a constant Float64 return

- Where: `src/softfloat_dispatch.jl:136`, `:142`, `:148` (unconditional `.bits` on the function result).
- Evidence: VERIFIED-BY-EXECUTION. `reversible_compile(x->1.0,Float64)` fails with `VoidType reached _type_width`; so do `reversible_compile(x->x==x,Float64)` and `reversible_compile(x->Int64(x),Float64)`.
- Failure scenario: a function can accept the wrapper but return a perfectly ordinary Float64 constant, which has no `.bits` property. Predicate outputs also fail despite valid comparison dispatch. Integer-returning functions additionally need conversion methods; the wrapper currently has neither output adaptation nor a useful diagnostic.
- Fix: adapt outputs by type (SoftFloat → bits, ordinary Float64 → reinterpret, supported integers/Bool → their values), and validate unsupported result types explicitly before extraction. Add conversion dispatch separately where needed.
- Test: compile a constant Float64, a Boolean equality predicate, and an in-range Float64-to-integer conversion, including multiargument variants; check outputs and ancilla cleanup.
- Already tracked? Bennett-777 (closed) explicitly identifies the SoftFloat-result assumption, but its closure reports that `soft_fptosi` exists rather than repairing this API path. The original tracked diagnosis remains correct; the completion claim does not hold for this overload.

### F10 — [S2] Both power test files skip most subnormal-output binades

- Where: `test/test_softfpow.jl:203–204`, `:227–228`; `test/test_softfpow_julia.jl:185–186`, `:209–210`; required contract in `CLAUDE.md:44–45` (rule 13, subnormal-output convention).
- Evidence: VERIFIED-BY-EXECUTION and source inspection. For base 0.5, the exact target grids yield only 9 or 19 distinct subnormal binades; the five-fraction grid has only 3 nonzero subnormal outputs. The small-base sweeps interpolate the 53-binade interval with only 10 or 20 steps, so adjacent targets differ by **5.3 or 2.65 binades**. The near-one sweeps use only five fractions, separated by **13.25 binades**. Changing the base does not fill those target-binade gaps. The musl test also uses a system-libm oracle and ≤2 ULP, whereas the mandatory convention calls for Base and ≤1 ULP.
- Failure scenario: the tests are labeled mandatory subnormal-output sweeps, but a defect isolated to many intermediate output binades is never exercised. This is the same coverage pattern the post-mortem convention was meant to prevent. No new numerical failure in the missed regions is asserted here.
- Fix: parameterize by the target output exponent `t` and sweep `t=-1075:0.25:-1022`, deriving `y=t/log2(x)`. Count actual subnormal outputs/binades; include both signs where valid, endpoints, and neighbors. Retain a separate musl-oracle comparison if desired, and explicitly resolve any genuine Base-vs-libm tolerance exception instead of silently weakening rule 13.
- Test: assert all 52 subnormal binades are visited for representative bases, plus strict Julia-path bit equality and the approved tolerance for the musl path.
- Already tracked? Bennett-fnxg is closed and its stated requirement is correct; these later power tests do not satisfy it.

### F11 — [S2] The documented power accuracy bound contradicts a 14-ULP native discrepancy

- Where: `src/softfloat/fpow.jl:686–692`; `src/softfloat/fpow_julia.jl:14–16`; `test/test_softfpow.jl:180–189`, `:245–266`.
- Evidence: VERIFIED-BY-EXECUTION. `x=0.01; y=-1022.0/log2(x)` gives input bits `0x3f847ae147ae147b`, `0x40633a7146f72a42`. `soft_pow` returns `0x000ffffffffffff2`; Base `x^y` returns `0x000fffffffffffe4`: **14 ULP apart**, exceeding the stated ≤2-ULP full-domain bound. Evaluating the exact binary inputs at 512-bit BigFloat precision and rounding once gives `0x000ffffffffffff2` (soft is 0 ULP from that rounded reference, Julia is 14 ULP away).
- Failure scenario: callers relying on the primitive’s native-accuracy bound receive a larger discrepancy in the subnormal region. The test deliberately accepts a difference of 1–100 ULP and incorrectly claims both results are within approximately 0.5 ULP of truth; they cannot both be, and the executed high-precision oracle refutes it. This does **not** establish a mathematical accuracy bug in the musl result; it establishes the false native-comparison contract.
- Fix: reconcile the primitive’s advertised bound with its approved musl-vs-Julia policy. If ≤2 ULP against Base remains the requirement, implement that behavior; otherwise explicitly scope the exception and direct Julia-native callers to the Julia-specific implementation once F6 is repaired. Remove the false mathematical-error explanation and use an independent high-precision oracle when claiming accuracy against real arithmetic.
- Test: pin the exact inputs against both Base and high-precision truth under separately named contracts. Do not use a test that requires disagreement with Base as evidence for a universal agreement bound.
- Already tracked? Bennett-jexo and Bennett-ys0d describe deliberate separate reference implementations; that policy is real. Bennett-jexo fixes the Julia-facing last-bit contract, but the retained musl docstring and the claim that both answers are within 0.54 ULP of truth remain incorrect.

## Unconfirmed suspicions

- `_rp_fromfraction` (`fsin.jl:399–443`) underflows unsigned shift counts when the leading-bit position is below 26 (high part) or 53 (tail). Direct helper execution confirms `_rp_fromfraction(UInt64(0),UInt64(3))` yields two copies of `2^-128`, whose sum is `2·2^-128` instead of `3·2^-128`; a `(2^90+3)` numerator also gets its tiny tail wrong. **Public trig impact is unconfirmed**: no Float64 argument was found whose Payne–Hanek fraction makes this matter after rounding. Do not conflate it with F1's proven table typo. Repair signed left/right alignment or document and prove the stronger caller precondition; add direct small-integer fraction tests. This is not counted as a confirmed public-operation finding.


## What is sound (brief)

- Core arithmetic passed 1.8 million raw-bit comparisons, plus special-value matrices, exponent/cancellation probes, and boundary grids. Full-product FMA and the corrected subnormal normalization should be preserved.
- Conversion and rounding sweeps, 750,000 UInt128 helper checks, and denser transcendental underflow probes passed. The earlier exp-underflow catastrophe was not reproduced.
- All 60 primitive IRs contain no runtime floating-point arithmetic/conversion instructions; 59 parse successfully (F6 is the exception). Constant exp tables use QROM, verified over all 256 entries with ancilla cleanup.
- Float32 entry rejection works. `soft_fptosi` matches its documented unsafe-truncation contract; checked Julia `Int64(x)` deliberately has different error semantics.

## Nits (S4)

- `softfloat_common.jl:369–370` says Julia `x << 64 == x`; public Julia shifts zero an unsigned 64-bit value at 64, while low-level LLVM shifts need guards. Correct the language-level explanation; keep the safe clamps.
- `fsin.jl:89` names threshold `0x413921fb` as `2^28·π/2`; that high word corresponds to approximately `2^20·π/2`. This selects the accurate Payne–Hanek path earlier; no wrong result follows merely from this naming error. Correct the name/comments.
- Dead exploratory scaffolding remains in `fmul.jl:94–124` and `fsin.jl:614–617`; delete unused calculations/placeholder only after confirming gate counts. C4’s observation is still accurate.
- Four `_MAX/_MIN_EXP_{E,2}_BITS` constants are defined identically in both `fexp.jl:176–180` and `fexp_julia.jl:91–107`. Centralize or namespace them so a future edit cannot change both implementations through include order. Module/export counters (“32”, “39”) also disagree with the actual 60 exported primitives.

## Coverage log

- All **60 exported primitives** were checked through actual pinned LLVM extraction: **zero runtime floating-point arithmetic/conversion instructions** were found; **59/60 ParsedIR extractions succeeded**, with only `soft_pow_julia` failing (F6). Float-valued source constants fold before execution. The library is not globally branchless: pow has real branches/loop, and sin's extracted IR had 9 blocks; branchless source comments should not substitute for IR inspection.
- `_EXP_TAB` lookup extracted as one constant global plus one variable GEP, selecting the existing QROM lowering (`lowering/aggregate.jl:298–304`). A UInt8-index wrapper compiled to 20,954 gates; all 256 entries matched with explicit `simulate(c,UInt64,i)` output interpretation and reversibility passed. An initial signed-output comparison counted 65 negative table words as mismatches; that was a probe interpretation error, resolved by the typed simulator overload.
- Existing individual tests still pass despite the confirmed defects: `test_softfexp.jl` 86+64 assertions, `test_softfsin.jl` 234, `test_softfpow.jl` 215, run under bounds checking in isolated modules in one Julia process. No full suite was run.
- Adversarial helper validation: seed `0xb534`, 750,000 UInt128-oracle checks of wide multiply/add/subtract/negate and right-jam shifts (−1, 0, 1, 2, 63, 64, 65, 127, 128, 129, 2048) passed. Another 100,000 exponent-spanning multiply/divide/FMA cases each passed, including `fma(x,y,-(x*y))` cancellation. Cartesian core special-value matrices passed, including multiple distinct NaNs in FMA.
- Denser underflow checks passed: exp/exp2 and Julia variants at 0.125 input steps; ten odd/tiny-output functions across all 52 subnormal binades, both signs, and four significands (416 each); 30,000 targeted subnormal-output samples for each power variant (musl max 1 ULP, Julia exact). The old exp-underflow catastrophe was not reproduced.
- `soft_fptosi` intentionally follows unsafe LLVM/x86 truncation semantics, not checked `Int64(x)`: NaN/Inf/out-of-range yielded `0x8000000000000000`, while checked Julia conversion throws InexactError; 1.75 truncates to 1 while checked conversion also throws. This is documented and is not itself a primitive bug.
- Julia 1.12.3, `--startup-file=no --project --check-bounds=yes`: seed `0xb526`, 300,000 independent raw-bit samples per operation gave **zero mismatches** for add, subtract, multiply, divide, square root, and FMA (1.8 million comparisons). Square root used `ccall(:sqrt, ...)` to include negative-domain IEEE results. This does not establish exhaustive correctness.
- Core arithmetic pre-normalizes subnormals and carries guard/round/sticky bits through final packing. FMA preserves a full 128-bit product, including the low-limb fold after catastrophic cancellation.
- Seed `0xb528`: 200,000 raw inputs each for sitofp, fpext, fptrunc, fptosi, and fptoui passed their native/unsafe-trunc oracle; another 200,000 each for floor, ceil, trunc, ties-even round, and ties-away round passed. Checked Float32 compile is rejected with an explicit ArgumentError.
- Seed `0xb527`: 100,000 candidates per unary transcendental, alternating raw bits and function-specific finite ranges. Within the valid real domain, exp/exp2/log/log2/log10/atan/asin/acos/sinh/cosh/tanh/asinh/acosh/atanh/log1p/expm1 stayed within 2 ULP; exp_julia/exp2_julia had zero bit mismatches. Domain-filtered candidate counts vary. Trig failures are F1.
- Environment: Julia **1.12.3**, all probes invoked with `--startup-file=no --project --check-bounds=yes`; deterministic MersenneTwister seeds `0xb526` through `0xb536` (individual purposes recorded above). No execution was sandbox-blocked. A few probe-harness errors (unqualified non-exported names, verifier signature, BigInt negative-power syntax) were corrected and rerun; they are not repository findings.
- Reviewed all 35 softfloat source files at the algorithm/dispatch level: complete core, conversion, comparison, rounding, and min/max implementations; exp and Julia-exp kernels; log main/near-one/change-of-base paths; both pow reconstruction/classification/main paths and powi; sin/cos kernels, Cody–Waite/Payne–Hanek machinery; tan kernel; atan/atan2; asin/acos rational and endpoint formulas; hyperbolic and inverse-hyperbolic regime selection; log1p/expm1. Repetitive coefficient/table entries were sampled and exercised numerically; only the complete 19-limb 1/(2π) table was independently regenerated. No claim that all other copied coefficients were independently derived.
- Read all public SoftFloat methods and Float64 compile wrappers, relevant includes/CompileOptions forwarding in Bennett.jl, the FP callee registry, and the QROM dispatch/callee-lowering lines needed to follow cross-scope findings. Tested all 60 exported primitive extractions, not every possible caller IR shape or optimization configuration.
- Test audit: strict core bits/raw-bits coverage, l5v8 dispatch/E2E distinction, k2w6 NaN assertions, pow/pow_julia actual special-case oracles and underflow grids, and every transcendental’s subnormal-range test structure. Musl exp uses 0.25/0.5 steps; Julia exp/exp2 use 2,000-point random subnormal sweeps; tiny-output functions cover the full subnormal input-binade lattice; atan2 fixes x=1 and varies y; cos/cosh/acos/acosh/log variants document no applicable subnormal-output regime; those claims were inspected rather than exhaustively proved over all bit patterns. Power’s gaps are F10. Negative-side coverage for sin/tan/atan/asin/atan2 is weaker in the existing lattice sweeps; this review additionally checked both signs where relevant.
- Additional completed probes: 200,000 comparison checks across all ten predicates (zero mismatches); 5,476-case adversarial grids each for add/multiply/divide (zero mismatches); Int64 extreme/tie sitofp checks; 24 BigFloat-oracle subnormal helper checks around shifts 52–57 (zero mismatches); 200,000 raw-bit atan2 pairs (max 1 ULP); 250,000 focused samples each around transition/cancellation regions for expm1, sinh, cosh, tanh, log1p, asinh, acosh, atanh (all within 2 ULP). Positive-base power random candidates: 99,969 valid inputs per variant, musl max 1 ULP and Julia exact.
- Read the Bennett-wigl post-mortem (`worklog/018...:1–95`) and C4 architecture report sections on contracts, tables, helpers, coupling, and redesign. Confirmed C4’s dead-code/duplicate-constant concerns and power branching. Refuted its claimed rounding-boundary defect as a demonstrated arithmetic bug: in the actual GRS format the half-minimum-subnormal guard occurs at shift 53; shift 56 is already below that, so the documented theoretical argument misidentifies the rounding bit. Broad and directed validation found no primitive mismatch there.
- Limits: full-suite execution, full 64-bit exhaustion, alternative hosts/Julia versions, all 60 full circuit syntheses, all native NaN conventions of every tolerance-based transcendental, and proof of `_rp_fromfraction` public-path reachability were not performed. Expensive numerical circuits were assessed primarily by executing their integer kernels; actual circuits were checked for mixed equality, min, and exhaustive QROM. No source, test, worklog, issue database, or git state was intentionally changed; only this report was written.
