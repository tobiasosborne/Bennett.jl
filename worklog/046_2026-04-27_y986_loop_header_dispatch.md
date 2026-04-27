# Bennett.jl Work Log

## Session log — 2026-04-27 — Bennett-cklf / U128 close (resolve! SSA-path width assert)

**Shipped:** `resolve!` (src/lower.jl:198-210) now asserts `length(wires) == width` on the SSA path. Pre-cklf the function silently discarded the caller's `width` argument and returned `var_wires[op.name]` regardless of length match. Pointer-typed operands (`width=0`) are exempt — pointers carry no width by convention.

**Why:** Bennett-cklf / U128 — review F5: the SSA path's silently-discarded width argument let downstream consumers index into wire vectors based on their advertised width while the actual length might differ, producing opaque BoundsErrors or silent miscompilations. Per CLAUDE.md §1 fail-loud, the contract should be asserted.

**Mode:** direct grind. 5-line addition, plus precise error message.

**Test coverage:** `test/test_cklf_resolve_width_assert.jl` (7 assertions / 4 testsets):
- Matched width: returns wires unchanged.
- Pointer exemption (width=0): accepts any wire-vector length.
- Mismatched width: precise error containing "cklf", "length(wires)=N", "width=M".
- Undefined SSA: error fires first (precedes the length check).

**Adjacent — pattern alignment:** mirrors Bennett-fq8n / U84 (`lower_phi!` width assertion at lower.jl:1272+). Same shape: SSA operand reaches a width-aware caller, length-vs-width must match or fail loud.

**Regression check:** Full Pkg.test 83,756 / 83,758 pass + 2 pre-existing broken (4m20s). Test count 83,749 → 83,756 (+7). All existing `resolve!` callers satisfy the new contract — no need to fix any caller.

**Gotchas / Lessons:**

1. **Pointer-typed operands are width=0 by convention.** I almost wrote a stricter assertion `length(wires) == width` unconditionally, which would have tripped on every pointer SSA reference. The `width != 0` exemption pre-empts that. CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK" warns about pointer-typed phi/select; the same width=0 sentinel applies here.

**Filed (follow-ups):** none.

**Test count:** 83,749 → **83,756** (+7).

**Next agent — start here:** Continue bugs-only. Remaining: `y56a` (triple-redundant integer division — investigation+dedup, post-salb easier), `yys3` (manual 128-bit arithmetic — investigation), `q04a` / `jc0y` (3+1 refactors, larger scope).

---

## Session log — 2026-04-27 — Bennett-qmk6 / U82 + Bennett-dq8l / U81 close (precise _type_width error dispatch)

**Shipped:** `_type_width` (src/ir_extract.jl) now dispatches `VectorType` (qmk6), `StructType` (qmk6-related), and `VoidType` (dq8l) explicitly with precise error messages. Pre-fix all three fell through to a generic "unsupported LLVM type for width query: <type>" message.

**Why:** Two beads, same site, one fix. qmk6 (vector-valued returns produce misleading "width query" error) and dq8l (void-return non-sret crashes in `_type_width` with generic message) both fired from `_type_width`'s catch-all else-branch. Consolidating the fix per CLAUDE.md §1 (fail loud with context) and §12 (don't proliferate dispatch sites).

**Mode:** direct grind — error-message clarity, no semantic change.

**Test coverage:** `test/test_qmk6_dq8l_type_width_errors.jl` (21 assertions / 4 testsets):
- VectorType: 3 vector shapes (i32×4, i64×2, i8×16) — error names "VectorType" + cites cc0.7 / qmk6.
- VoidType: error names "VoidType" + cites dq8l, points at upstream caller.
- StructType: error names "StructType" + suggests sret / extractvalue.
- Existing happy paths: int/float/double/half/array all unchanged (regression guard).

**Gotchas / Lessons:**

1. **LLVM.jl float type constructors are named `DoubleType()` / `FloatType()` / `HalfType()`, NOT `LLVMDouble()` etc.** The latter are TYPE NAMES (the Julia structs that wrap LLVM's typed value), not constructors. My first test attempt called `LLVM.LLVMDouble()` and got `MethodError: no method matching` for all three. Lesson: when adding tests that construct LLVM.Type instances, use the `*Type()` constructors per LLVM.jl's API.

2. **Two beads fixed in one commit is fine when the fix is single-site.** Per chunk 045 directive, "DO NOT file new follow-up beads as a substitute for fixing a real bug" — but consolidating two beads that the same edit closes isn't filing follow-ups, it's just efficient batching. Worklog calls out both bead IDs; commit message cites both.

**Filed (follow-ups):** none.

**Test count:** 83,728 → **83,749** (+21).

**Next agent — start here:** Continue bugs-only. Remaining: `cklf` (resolve! silently discards width arg — similar error-clarity work), `y56a` (triple-redundant integer division — investigation+dedup, post-salb easier), `yys3` (manual 128-bit arithmetic — investigation), `q04a` / `jc0y` (3+1 refactors, larger scope).

---

## Session log — 2026-04-27 — Bennett-ys0d / U134 close (soft_exp accuracy contract docstring)

**Shipped:** `soft_exp` and `soft_exp2` docstrings in src/softfloat/fexp.jl now include a "Variants" table making the bit-exactness contract explicit: `soft_exp` is bit-exact vs musl, `soft_exp_julia` is bit-exact vs `Base.exp`. Same for exp2. New regression test `test/test_ys0d_exp_accuracy_contract.jl` (24 assertions) pins the empirical contract.

**Why:** Bennett-ys0d / U134 — review F6 flagged that `soft_exp` is off-by-1-ULP on ~0.9% of inputs vs `Base.exp` while `soft_exp_julia` is bit-exact. Discoverability bug: the user-facing default IS already correct (`Base.exp(::SoftFloat) = soft_exp_julia`, src/Bennett.jl:413), but a direct caller of `soft_exp` could be surprised by the gap.

**Mode:** direct grind, doc-only.

**Empirical confirmation (50k random samples in [-30, 30]):**
- `soft_exp` vs `Base.exp`: 0.91% disagreement (matches the bead's claimed ~0.9%).
- `soft_exp_julia` vs `Base.exp`: 0.0% disagreement.

**Test coverage:** `test/test_ys0d_exp_accuracy_contract.jl` (24 assertions / 5 testsets):
- `soft_exp_julia` bit-exact vs `Base.exp` (50k samples → 0% rate).
- `soft_exp` ≤ ~2% off vs `Base.exp` (regression-guard upper bound; empirical baseline pinned in the upper-bound + lower-bound assertions so accidental "improvement" trips it too).
- `soft_exp2_julia` bit-exact vs `Base.exp2` (300-range samples → 0% rate).
- `Base.exp(::SoftFloat)` routing test: 11 representative inputs → soft_exp_julia output matches Base.exp output bit-for-bit.
- `Base.exp2(::SoftFloat)` routing: 9 representative inputs.

**Adjacent docstring updates:** `soft_exp` and `soft_exp2` now have a 3-row "Variants" table at the top of their docstrings explicitly naming `_julia` and `_fast` siblings + their accuracy contracts.

**Gotchas / Lessons:**

1. **The bug isn't in soft_exp's accuracy — it's in API discoverability.** soft_exp IS bit-exact vs musl (its documented contract). The musl bit-exact algorithm differs from Julia's by 1 ULP on ~0.9% of inputs. The fix isn't to change soft_exp; it's to make sure users know which variant matches their oracle.

2. **The user-facing default was already correct.** Bennett.jl:413-414 routes Base.exp / Base.exp2 to the `_julia` (bit-exact) variants. So Julia code calling `Base.exp` on a SoftFloat gets bit-exact for free. The docstring update pre-emptively prevents direct-soft_exp-callers from being surprised.

3. **Lower-bound regression check matters.** The test asserts `0.001 < rate < 0.02` for soft_exp — both upper AND lower bounds. The upper bound catches accidental degradation; the lower bound catches accidental "soft_exp accidentally became bit-exact" (which would mean someone changed the algorithm without realising it crossed the musl boundary, worth investigating). Pattern borrowed from chunk 045's gate-count regression baselines (CLAUDE.md §6).

**Rejected alternatives:**

- **Retire `soft_exp` (alias to `soft_exp_julia`)** — discarded; soft_exp's musl-bit-exactness is the load-bearing contract for users who care about cross-implementation reproducibility (e.g. testing against Arm Optimized Routines). The bead lists this as one option but the "document deprecation" path is just removing the wrong primitive.
- **Rename `soft_exp` to `soft_exp_musl`** — discarded; would be a breaking API change for direct callers. The docstring update achieves the same discoverability without churn.

**Filed (follow-ups):** none.

**Test count:** 83,704 → **83,728** (+24).

**Next agent — start here:** Continue bugs-only. Remaining: `y56a` (triple-redundant integer division — post-salb easier), `yys3` (manual 128-bit arithmetic), `q04a` / `jc0y` (3+1 refactors).

---

## Session log — 2026-04-27 — Bennett-xiqt / U133 close (subnormal flush boundary — investigated, doc-only)

**Shipped:** see git log; new regression test `test/test_xiqt_subnormal_boundary.jl` (26 assertions) + docstring update on `_sf_handle_subnormal` (src/softfloat/softfloat_common.jl) documenting the investigation finding.

**Why:** Bennett-xiqt / U133 — review F8/M6 flagged `_sf_handle_subnormal`'s `flush_to_zero = shift_sub >= 56` boundary as potentially dropping the IEEE-754 RTNE round-up case for values whose true magnitude is just above half of smallest subnormal.

**Mode:** direct grind, "investigated, doc-only" disposition (chunk 045 pattern, cf. 2yky / 3of2).

**Investigation finding:** the boundary is theoretically RTNE-incorrect at `shift_sub == 56` with `wr` bit 55 set, BUT no current caller produces such inputs that disagree with `Base.*`:

- 200k+ random `soft_fmul` inputs in subnormal-range: 0 disagreements vs `Base.*`.
- 200k+ random `soft_fdiv` inputs: 0 disagreements vs `Base./`.
- 100k each `soft_fadd` / `soft_fsub` / `soft_fma` (with c=0): 0 disagreements vs `Base.{+,-,fma}`.

**The boundary IS exercised:** at `shift_sub ∈ [56, 60]` (~0.4% of fmul calls in the random sweep). And wr's bit 55 IS always set in those cases. But the wr encoding at the boundary doesn't have a naive "bit 55 = round bit" reading — for all observed inputs, the TRUE mathematical value is below half of smallest subnormal, so `Base.*` also rounds these to ±0.

**Test coverage:** `test/test_xiqt_subnormal_boundary.jl` (26 assertions / 3 testsets):
- Helper-level: pinned current behavior at `shift_sub ∈ {0, 55, 56}`.
- End-to-end: 5k random calls each of fmul/fdiv/fadd/fsub vs `Base.*`, asserting 0 disagreements.
- Targeted: handcrafted boundary cases (`a=2^-1022`, `b=k*2^-53` for `k ∈ {1.0, 1.1, 1.25, 1.5, 1.75}`) — all match `Base.*`.

The targeted boundary cases (e.g. `a*b3 = 1.5*2^-1075`) DO produce smallest subnormal (`0x1`), confirming that fmul handles the IEEE-754 round-up correctly via a different code path (shift_sub = 53 in that case, NOT 56).

**Gotchas / Lessons:**

1. **"Theoretical bug" beads need empirical verification before fixing.** The review's analysis of the helper's logic was correct in isolation, but the helper is only called from soft_f* code that pre-scales the wr and result_exp such that the "round-up" case manifests as `shift_sub ∈ [50, 55]`, NOT 56. Fixing the helper to handle shift_sub == 56 "correctly" would have changed observable behavior for 0 inputs and risked breaking the 200k empirically-verified outputs.

2. **The disagreement scan should NOT filter on "near-zero region" before counting.** My first scan filtered for `(base_r & 0x7FFF...) <= 16` and got 0 disagreements — but I'd already filtered out potential bugs at higher magnitudes. Re-running without the filter (just "any disagreement") was the right cross-check; still 0.

3. **Helper-level tests MUST be paired with end-to-end tests.** I instrumented `_sf_handle_subnormal` to histogram shift_sub values and confirmed the boundary IS exercised — without that, I might have wrongly concluded the bug was unreachable. The instrumented trace + the 0-disagreement empirical scan together give the full picture.

**Rejected alternatives:**

- **Fix the boundary at shift_sub == 56 to handle round-up** — would change behavior for 0 inputs (since no fmul/fdiv/fma/fadd input produces a wr that disagrees with Base.* at the boundary). Net cost: gate-count shift in soft_f* lowerings AND the risk of breaking the empirically-verified 0-disagreement behavior. Out of scope for a P3 BUG with no observable failure.
- **Add a `@warn` log at shift_sub == 56 with bit 55 set** — would fire ~0.4% of the time on legitimate inputs. Useless noise.

**Filed (follow-ups):** none. If a future caller IS constructed that disagrees with `Base.*` at the flush boundary, the new regression-guard test will trip and reopen this bead.

**Test count:** 83,678 → **83,704** (+26).

**Next agent — start here:** Continue bugs-only. Remaining: `ys0d` (soft_exp 0.9% off-by-1-ULP), `y56a` (triple-redundant integer division), `yys3` (manual 128-bit arithmetic), `q04a` / `jc0y` (3+1 refactors).

---

## Session log — 2026-04-27 — Bennett-tpg0 / U135 close (_sf_normalize_to_bit52 zero-input contract)

**Shipped:** see git log; `_sf_normalize_to_bit52` in src/softfloat/softfloat_common.jl now handles `m == 0` explicitly, returning `(0, e)` unchanged. Pre-tpg0 the function had a caller-trust contract: `m == 0` produced `(0, e - 63)` (every CLZ stage shifts because no leading 1 is found), documented as "callers handle zero inputs via the select chain before using m". Defensive removal of the contract.

**Why:** Bennett-tpg0 / U135 — review F13: pathological behaviour on m==0 with caller-trust contract. Per CLAUDE.md §1 fail-loud, silent garbage-exponent output is wrong. Multiple callers (fdiv, fmul, fma, fsqrt) all pre-guard zero today, but a future caller that doesn't would silently get nonsense.

**Mode:** direct grind. Pure defensive: branchless `ifelse` substitute pattern using `IMPLICIT` (1<<52) as an internal sentinel during the CLZ (a no-op for the already-normalized form), then restore the original `m=0` and `e` at exit.

**Byte-identicality argument:** for any `m != 0`, `m_zero` is `false`, so the entry `ifelse` picks `m` unchanged and the exit `ifelse` picks the CLZ result. The CLZ logic is unchanged. Therefore output for `m != 0` is byte-identical pre-vs-post fix. Empirically confirmed: full Pkg.test green, all softfloat tests (fdiv, fmul, fma, fsqrt) byte-identical.

**Test coverage:** `test/test_tpg0_normalize_zero_input.jl` (454 assertions / 4 testsets):
- m == 0 returns `(0, e)` for 8 representative `e` values (was `(0, e - 63)` pre-fix).
- m != 0 already-normalized inputs are no-ops (24 cases).
- m != 0 subnormal inputs normalize correctly (handle-table cases, 14 assertions).
- 200 random subnormal inputs cross-checked against Julia's `leading_zeros` oracle (400 assertions).

**Full suite green:** Pkg.test 83,678 / 83,680 pass + 2 pre-existing broken (3m59s). Test count 83,224 → 83,678 (+454, exact match).

**Gotchas / Lessons:**

1. **The `IMPLICIT = 1 << 52` sentinel is the right choice for the substitute** because the CLZ specifically looks for the bit-52 leading 1. With the substitute in place, `need32` / `need16` / ... / `need1` are all `false` (the bit-52 bit IS set), so no shift is performed and `e` is unchanged. Then the exit `ifelse` discards the unchanged-m=IMPLICIT and returns 0.

2. **Hand-computed test tables are error-prone for CLZ-style functions.** My first table had `(UInt64(0xFFFFFFFF), 20)` — leading 1 is at bit 31, so shift = 52 - 31 = 21, not 20. Switched to using `leading_zeros(m)` to compute the expected shift dynamically. Lesson: for any CLZ test, prefer the language-builtin oracle over hand-typed shift counts.

**Rejected alternatives:**

- **`error()` on m == 0** — rejected; this function is `@inline`d into compiled SoftFloat code that becomes a callee. An `error()` would emit `@ijl_throw` in the IR, breaking `lower_call!` extraction (same problem we hit with salb).
- **No defensive guard, just docstring** — rejected; the bead explicitly asks "Handle m == 0 explicitly (either return early or assert it cannot happen)". Branchless guard satisfies the "return early" form without a branch.

**Filed (follow-ups):** none.

**Test count:** 83,224 → **83,678** (+454).

**Next agent — start here:** Continue bugs-only. Remaining softfloat tier: `xiqt` (subnormal flush boundary), `ys0d` (soft_exp 0.9% off-by-1-ULP). Then `y56a`, `yys3`, `q04a`, `jc0y`.

---

## Session log — 2026-04-27 — Bennett-bjdg / U80 close (precise constant-operand error messages) + Sturm-cvnb file

**Shipped:** see git log; `_operand` in src/ir_extract.jl now dispatches `ConstantFP`, `PoisonValue`, `UndefValue`, and `ConstantPointerNull` operands to precise error messages naming the kind, the value's textual form, and the relevant Bennett-side limitation. Pre-bjdg these all fell through to the misleading "unknown operand ref ... — the producing instruction was skipped or is not yet supported; check the cc0.x gaps in the extractor" — wrong because there is no producer for a constant.

**Why:** Bennett-bjdg / U80, surfaced as a gotcha during d77b earlier today (chunk 046 d77b entry, gotcha #2). User expects a Float64 literal in operand position to either be lowered (via SoftFloat) or emit a clear "Float64 constants not supported" message, not a hunt for a missing extractor branch.

**Mode:** direct grind. Error-message-only change to `_operand`'s else-branch fallthrough. No semantic change.

**Test coverage:** `test/test_bjdg_constant_operand_errors.jl` (4 assertions / 2 testsets):
- `(a::Float64, b::Float64) -> a < b ? 1.0 : 0.0` → asserts the new error mentions "ConstantFP" and does NOT contain the misleading "producing instruction was skipped" phrase.
- `(a::Float64, b::Float64) -> 1.0` → same.

PoisonValue and UndefValue paths covered by the dispatch but not exercised in the test (hard to trigger from Julia source without writing raw LLVM IR — the LLVM optimizer rarely emits these against optimize=false). The dispatch is mechanical and will fire when LLVM does emit them.

**Adjacent:** ConstantPointerNull dispatched via `LLVM.API.LLVMGetValueKind` because LLVM.jl doesn't expose a Julia-level type (pattern borrowed from `_ptr_identity` at src/ir_extract.jl:2210+).

**Full suite green:** Pkg.test 83,224 / 83,226 pass + 2 pre-existing broken (4m13s). Test count 83,220 → 83,224 (+4, exact match).

**Filed (follow-ups):** none for bjdg itself. Earlier in this session: `Bennett-cvnb` (P3 task) filed in response to a Sturm.jl feature request — see separate entry below.

**Test count:** 83,220 → **83,224** (+4).

**Next agent — start here:** Continue bugs-only. With salb + y986 + gboa + d77b + bjdg closed today, ~9 [bug] beads remain. Suggested order:
- **softfloat tier**: `tpg0`, `xiqt`, `ys0d` — each needs the §13 subnormal-output testset.
- **`y56a`** — triple-redundant integer division.
- **`yys3`** — manual 128-bit arithmetic (investigation).
- **`q04a` / `jc0y`** — yesterday's 3+1 filings.

---

## Session log — 2026-04-27 — Sturm.jl feature-request investigation, filed Bennett-cvnb (no Bennett-side code change)

**Shipped:** see git log around the bd-cache commit 811c4c7; `Bennett-cvnb` (P3 task) filed.

**Why:** Sturm.jl escalated a feature request for a `bennett_direct(lr)` entry point that bypasses the Bennett-1973 forward+copy+uncompute wrap for already-reversible LoweringResults. Sturm reported ~4× Toffoli + ~6 extra ancillae in their windowed Shor mulmod path (Sturm Session 74; 192s vs ~30s expected at N=15, c_mul=2).

**Investigation finding:** the fast path **already exists**. `bennett(lr)` at `src/bennett_transform.jl:101-105` short-circuits to forward-only emission when `lr.self_reversing == true`, validated by `_validate_self_reversing!` (Bennett-egu6 / U03 contract probe battery). Bennett's own `lower_tabulate` (src/tabulate.jl:208-212) is the canonical caller; it sets `self_reversing=true` via the 9th positional arg of the LoweringResult constructor. Sturm's `qrom_lookup_xor!` uses the 7-arg backward-compat constructor (src/lower.jl:64-67) which silently defaults `self_reversing=false` → wrap is applied. README:137 documents the flag but discoverability is poor.

**Conclusion:** no Bennett-side code change required for Sturm to get the speedup. The Sturm-side fix is to change one constructor call to the 9-arg form passing `self_reversing=true`. Bennett-cvnb captures the discoverability improvement (add `bennett_direct` convenience alias + README "pre-reversed circuits" callout + bennett() docstring expansion) so future downstream users don't hit the same gap.

**Cited references** (in the bead):
- src/bennett_transform.jl:101-105 (existing fast path).
- src/lower.jl:48-74 (LoweringResult struct + 7-arg constructor that defaults `self_reversing=false`).
- src/tabulate.jl:208-212 (canonical `self_reversing=true` caller).
- src/qrom.jl:28-30 (Bennett's own emit_qrom! is garbage-free, matches Sturm's emit_qrom! contract).
- README.md:137 (existing — but unprominent — documentation).
- Sturm.jl Session 74 worklog, Sturm.jl-2qp, Sturm.jl-ao1, Sturm.jl-pw9 (Sturm-side context).

**Gotchas / Lessons:**

1. **Backward-compat constructors silently drop new fields.** The 7-arg LoweringResult constructor was added pre-self_reversing (Bennett-P1) and now silently defaults the flag to `false`. Downstream users not following Bennett.jl's history have no visibility into this. Lesson: when adding a new boolean flag with a non-trivial perf impact, surface it in the constructor signature OR add a deprecation warning to the older shorter-arity constructor pointing at the new one.

2. **README mentions ≠ README findability.** README:137 documents `self_reversing`. Sturm read it but didn't recognise it as load-bearing for their case. Lesson: a single-line mention buried in a feature list isn't enough for a flag with a 4× perf swing; needs a dedicated callout section for downstream library authors.

3. **External users' diagnoses are valuable but verify.** Sturm correctly identified the symptom (4× Toffoli, 6 extra ancillae) and traced it to "Bennett's compile overhead". Their proposed fix (new entry point) was based on an incorrect inference (wrap is unconditional). The correct mechanism existed; the user just couldn't find it. Always run the Sturm-side investigation step they proposed ("confirm in Bennett source...") before agreeing the API needs a new entry point.

**Rejected alternatives:**

- **Implement `bennett_direct` immediately** — declined for now; not a bug, and the per-the-directive bugs-only mandate takes priority. Filed as Bennett-cvnb for the next non-bugs cycle. Sturm can move forward by switching to the 9-arg constructor today.

**Filed:** `Bennett-cvnb` (P3 task) — Surface self_reversing fast-path discoverability for downstream users.

---

## Session log — 2026-04-27 — Bennett-d77b / U132 close (full LLVM fcmp predicate coverage)

**Shipped:** see git log around the next commit; 6 new soft_fcmp_* primitives (`ord`, `uno`, `one`, `ueq`, `ult`, `ule`) added to `src/softfloat/fcmp.jl`, registered in `_CALLEES_FP_CMP`, and wired into `ir_extract.jl`'s LLVM-fcmp dispatch table. Combined with the existing 4 (oeq, olt, ole, une) plus operand-swap dispatch for the four GT/GE forms (ogt → olt(b,a), oge → ole(b,a), ugt → ult(b,a), uge → ule(b,a)), every LLVM fcmp predicate now routes to a callee — pre-d77b 8 predicates (`one/ord/uno/ueq/ugt/uge/ult/ule`) raised `_ir_error("unsupported fcmp predicate $pred_int")`.

**Why:** Bennett-d77b / U132 — pre-fix, user code that emitted any of the 8 missing predicates failed at compile time with a fail-loud error (correct per CLAUDE.md §1, but blocks legitimate workloads). The bead listed all 10 missing predicates from the catalogue; 4 were already swap-derivable from existing primitives, leaving 6 genuine new implementations.

**Mode:** direct grind. New primitives are pure-Julia, branchless, with NaN-aware semantics derived from the existing `_either_nan` pattern factored out into a small helper. No core-pipeline algorithmic change; all behavior shifts gated on previously-rejected predicates.

**Implementation note (`une = !oeq`):** the existing `soft_fcmp_une = 1 - oeq` is correct because `!oeq` covers BOTH unordered (NaN) and ordered-not-equal cases — verified equivalent to the canonical `uno | one`. Left as-is; documented in the docstring.

**Test coverage:** `test/test_d77b_fcmp_predicates.jl` (1540 assertions / 8 testsets):
- 6 testsets × 144 (12 × 12 input pairs covering finite ±, ±0, ±Inf, NaN, denormal) = 864 direct primitive checks vs Julia oracles for `ord`, `uno`, `one`, `ueq`, `ult`, `ule`.
- 1 cross-check testset: existing 4 predicates (`olt`, `oeq`, `ole`, `une`) still match their Julia oracles after the fcmp.jl edit.
- 1 compiled-circuit testset: `(a::Float64, b::Float64) -> op(a,b) ? Int8(1) : Int8(0)` for each new predicate, simulating the IR-extraction → lowering path with both finite and NaN inputs.

**Adjacent test fixed in flight:** `test/test_kmuj_callee_groups.jl` pinned `length(_CALLEES_FP_CMP) == 4` and the total `n_grouped == 45`. Both updated to 10 / 51 with a comment citing d77b. Caught by the first full Pkg.test run (failed with 2 fails); fixed before re-running.

**Full suite green:** Pkg.test 83,220 / 83,222 pass + 2 pre-existing broken (4m14s). Test count 81,662 → 83,220 (+1558: 1540 d77b file + 18 from kmuj iterating over the larger group).

**Gotchas / Lessons:**

1. **`simulate(c, ::Type{T}, inputs)::T`** (the typed-output overload from Bennett-59jj) is **integer-only**. For Float64 IO compiled circuits, use the 2-arg form `simulate(c, (bits(a), bits(b)))` with `bits(x) = reinterpret(UInt64, x)`. This caught my first compiled-circuit testset attempt; the typed overload threw `MethodError: no method matching simulate(::ReversibleCircuit, ::Type{Int8}, ::Tuple{Float64, Float64})`. The simulator operates on raw bit-vectors, so Float64 inputs must be reinterpreted to UInt64 at the call site.

2. **The cc0.x ConstantFP gap** (Bennett-bjdg): `(a::Float64, b::Float64) -> a < b ? 1.0 : 0.0` fails extraction because `1.0` and `0.0` reach the IR as `ConstantFP` operands that ir_extract doesn't yet recognise. Worked around by returning `Int8(1) : Int8(0)` instead. The pinned compiled-circuit tests use the integer-result idiom.

3. **Pinned-count regression tests are easy to forget when adding registered callees.** `test_kmuj_callee_groups.jl` is the canonical lookout: any new entry in `_CALLEE_GROUPS` requires updating the per-group length and the total `n_grouped`. Saved by the full Pkg.test run; would have been caught earlier by grepping for `_CALLEES_FP_CMP` in tests before adding entries.

**Rejected alternatives:**

- **Implement only the 6 truly-missing primitives and skip ugt/uge** (treating them as "errors are fine, they're rare") — discarded; CLAUDE.md §1 wants fail-loud, but the catalogue and bead explicitly call out ugt/uge as missing. Adding the 4-line swap dispatch in ir_extract is trivial and gives complete LangRef coverage.
- **Refactor existing `soft_fcmp_olt` / `soft_fcmp_oeq` to share a `_classify(a, b)` helper returning `(a_nan, b_nan, both_zero, abs_lt, abs_eq, ...)` tuple** — would be cleaner but is a refactor, out of scope per the bugs-only directive. Filed mentally for a future refactor pass; not creating a follow-up bead per the directive ("DO NOT file new follow-up beads as a substitute for fixing a real bug").
- **Implement `false` (predicate 0) and `true` (predicate 15) as constant returns** — out of scope; bead doesn't list them. They'd be `iconst(0)` / `iconst(1)` rather than callees, which is structurally different.

**Filed (follow-ups):** none.

**Test count:** 81,662 → **83,220** (+1558 = 1540 from d77b file + 18 from kmuj iteration over larger group).

**Next agent — start here:** With salb + y986 + gboa + d77b closed today, 10 `[bug]` beads remain. Suggested order:
- **softfloat tier**: `tpg0` (`_sf_normalize_to_bit52` on m=0), `xiqt` (subnormal flush boundary), `ys0d` (`soft_exp` 0.9% off-by-1-ULP). Each needs the §13 `subnormal-output range` testset.
- **`y56a`** (P3) — triple-redundant integer division paths. Post-salb the `_soft_udiv_compile` is the canonical kernel.
- **`bjdg`** (P3) — ConstantFP/Poison/Undef in scalar operand → misleading error. Surfaced again as gotcha #2 above.
- **`yys3`** (P3) — manual 128-bit arithmetic.
- **`q04a` / `jc0y`** (both 3+1) — yesterday's filings.

---

## Session log — 2026-04-27 — Bennett-gboa / U139 close (zero-ancilla in-place op contracts)

**Shipped:** see git log around the next commit; explicit pre/post wire-state contracts added to `lower_add_cuccaro!` (src/adder.jl), the `:trunc` branch of `lower_cast!` (src/lower.jl), `lower_divrem!`'s truncation step (src/lower.jl), and `_cond_negate_inplace!` (src/lower.jl). New regression test `test/test_gboa_dirty_bit_hygiene.jl` (180 assertions) pins the contracts as load-bearing assertions: bypasses Bennett's outer reverse pass and runs the raw gate sequences via `Bennett.apply!` to verify input-preservation, in-place result correctness, and ancilla-zero invariants directly.

**Why:** Bennett-gboa / U139 — the review at `reviews/2026-04-21/07_arithmetic_bugs.md` F8 flagged that zero-ancilla in-place ops have implicit pre/post contracts. A reader can't tell from the code alone which wires must be zero before/after. Bennett's outer reverse pass cleans up whatever the gate sequence leaves dirty, so correctness holds today, but any future liveness-driven freeing pass that reuses these wires mid-circuit could silently miscompile (Bennett-3of2 / U112 is the canonical example: the Cuccaro `free!` rewrite passed `verify_reversibility` while producing sign-flipped sdiv outputs).

**Mode:** direct grind. Doc-only + a dedicated contract test; no algorithmic changes; no gate emission shifts. CLAUDE.md §2's 3+1 trip-wire is for behavior-changing changes to the core pipeline — adding docstrings + a wire-state assertion test doesn't qualify.

**Test coverage:** 180 assertions across 3 testsets (`test/test_gboa_dirty_bit_hygiene.jl`):
- **Cuccaro contract** (8 W ∈ {2,3,4,8} × 7 (a,b) cases × 3 contract checks ≈ 100+ assertions): a preserved, b ← (a+b) mod 2^W, ancilla X restored to 0.
- **`:trunc` source-wire preservation** (6 (F,T) sizes × 4 src values × 2 contract checks): src wires unchanged, r holds low T bits.
- **`_cond_negate_inplace!` cond+val invariant** (3 W × 2 cond × 4 val × 2 contract checks): cond preserved, val correctly negated/preserved (carry leak documented separately per Bennett-3of2 / U112).

**Adjacent test stays green:** `test_op6a_cuccaro_gate_count` 30/30, `test_division` 4819/4819, `test_gate_count_regression` 39/39 — confirms the docstring + contract-test additions are correctness-neutral. Full Pkg.test 81,662 / 81,664 pass + 2 pre-existing broken (4m15s). Test count 81,482 → 81,662 (+180, exact match).

**Gotchas / Lessons:**

1. **`Bennett.apply!` is the lowest-level simulation primitive** (src/simulator.jl:1-3): three single-line methods on `(::Vector{Bool}, ::NOTGate/CNOTGate/ToffoliGate)`. Tests that need to exercise raw gate sequences without the Bennett wrap can build a `bits = zeros(Bool, n)` and apply gates manually. This is how the gboa contract test bypasses `bennett()` to assert wire-state invariants directly. The `WireAllocator` exposes `.next_wire` which gives the upper bound on allocated wires.

2. **`_cond_negate_inplace!`'s carry leak is real and load-bearing** — the function emits MAJ-ripple-up gates that compute carries into the (W+1) `next_carry` wires and never UMA-ripple them back down. The wires get uncomputed by Bennett's OUTER reverse pass at simulate time. The gboa contract test pins the cond+val invariant but explicitly does NOT assert carry-zero; that would fail because the function leaves them dirty. Documented in the docstring's "Wire budget" section (Bennett-3of2 / U112) — left as-is by design.

3. **The contracts hold today; the test is a regression guard.** Unlike a typical RED-GREEN cycle where the test fails before the fix, this is a "the contract was always implicit; now it's load-bearing." Any future change that violates the contract — e.g. a free-list rewrite of Cuccaro, a liveness pass that reuses src wires post-trunc, a refactor of cond-negate that drops the cond-preservation gates — will trip the gboa test. That's the value, not RED-GREEN.

**Rejected alternatives:**

- **`@assert` runtime checks inside the lower_* functions** — Julia doesn't disable `@assert` by default, so this would impose unconditional runtime cost on every Cuccaro/trunc/divrem call. Test-time assertion via the contract test is the right shape: zero runtime cost, full coverage at CI / manual `Pkg.test`.
- **Env-flag-gated `@debug` logging of wire state** — would require building a snapshot mechanism, doesn't catch bugs unless someone enables the flag and runs every code path. The contract test is more disciplined.
- **Lower-level wrapper functions that enforce the contract** (e.g. `lower_add_cuccaro_safe!`) — adds API surface for no real benefit. The contract is a CALLER-OBLIGATION at the existing call sites; the docstrings make that explicit.

**Filed (follow-ups):** none. The contracts are now explicit at every site flagged by the review.

**Test count:** 81,482 → **81,662** (+180).

**Next agent — start here:** Continue bugs-only per the chunk-045 directive. With salb + y986 + gboa closed today, the next-pickup list (per the y986 close pointer + measurement):

- **`d77b`** (P3) — only 4 of 14 LLVM fcmp predicates implemented. Feature-shaped; verify whether documented scope cut or genuine bug.
- **softfloat tier**: `tpg0` / `xiqt` / `ys0d` — each needs the §13 `subnormal-output range` testset, mirror the `soft_exp` pattern.
- **`y56a`** (P3) — triple-redundant integer division paths. Now easier post-salb: `_soft_udiv_compile` is the canonical kernel, redundancy can be measured + removed.
- **`bjdg`** (P3) — ConstantFP/Poison/Undef in scalar operand → misleading error.
- **`yys3`** (P3) — 200+ LOC manual 128-bit arithmetic to avoid `__udivti3` / `__umodti3`. Investigation-shaped.
- **`q04a` / `jc0y`** (P3, both 3+1) — yesterday's filings; structural refactors.

---

## Session log — 2026-04-27 — Bennett-y986 / U05-followup-2 close (loop-header dispatch unification)

**Shipped:** see git log around the next commit; `lower_loop!` now routes header non-phi instructions through the canonical `_lower_inst!` dispatcher (12 IR types) instead of the pre-y986 4-type cascade (IRBinOp / IRICmp / IRSelect / IRCast) with no `else`. The iteration-LOCAL ctx pattern that already existed for body blocks (Bennett-jepw) is hoisted to the top of the iteration and reused for both header-body and body-block dispatch. Fail-loud guarantee comes from `_lower_inst!`'s catch-all (lower.jl:190) per CLAUDE.md §1.

**Why:** Bennett-y986 / U05-followup-2 — the 4-type cascade silently dropped IRCall, IRStore, IRLoad, IRAlloca, IRPtrOffset, IRVarGEP, IRExtractValue, IRInsertValue, and any non-loop-carried IRPhi appearing in the loop header block. Original defect-1 from Bennett-httg / U05; deliberately preserved during the U05 MVP to protect Collatz / soft_fdiv gate-count baselines, then again during Bennett-jepw (chunk 045) for the same reason. Largest open compiler bug after jepw closed.

**Mode:** 3+1 protocol per CLAUDE.md §2. Two `Plan` proposers in parallel with full prompt context (CLAUDE.md, the relevant code, the bead, the gate-count concern). Synthesis below.

**3+1 outcome:**
- **Proposer A → Option (a)**: full route through `_lower_inst!`, delete the cascade. Crucial empirical claim: post-U27 `_pick_add_strategy(:auto)` returns `:ripple` regardless, so byte-identical for the 4 fast-path types even with full route. Argues §12 (no duplicated dispatch) wins.
- **Proposer B → Option (b)**: hybrid with lazy `header_fallback_ctx` for non-fast-path types only. Argues §6 baselines tilt toward smaller blast radius.
- **Synthesis (the +1)**: Option (a) is cleaner if A's empirical claim holds. Risk is small and **measurable** — snapshot Collatz gate count pre-patch, apply A, re-measure. Pinned baselines in `test_gate_count_regression.jl` already prove byte-identicality for non-loop functions; Collatz needs empirical confirmation.

**Empirical confirmation (the load-bearing measurement):** Pre-patch Collatz Int8 K=20 = `total=14074, Toffoli=2320, ancilla=8868`. Post-patch byte-identical (T3 in the new test pins these exact values). Proposer A's claim about `:auto → :ripple` collapse holds.

**Test coverage:** `test/test_y986_loop_header_dispatch.jl` — 84 assertions across 5 testsets, dual-track:

- **Track A (hand-built ParsedIR)** — bypasses LLVM to deterministically exercise the bug surface. T1 builds a single-block loop with `IRCall(_soft_udiv_compile)` directly in the loop header (the "LLVM-coalesced body into header" shape). Pre-fix the IRCall would be dropped, leaving `acc' = acc + d` reading an undefined `:d` SSA name → resolve! crash; post-fix the call lowers each iteration. T2 asserts strict K-scaling: K=4 gates > 2× K=1 gates — proves the per-iteration call is genuinely emitted.
- **Track B (regression baselines)** — T3 pins Collatz at exactly `14074/2320/8868` (byte-identical guarantee, AND oracle agreement for Int8(1):Int8(30)). T4 pins x+1 baseline at 58/12 (sanity that non-loop paths are untouched). T5 forces `add=:cuccaro` on a simple accumulator: confirms the iter ctx's `:ripple` override is load-bearing — without it, an explicit `:cuccaro` caller would have phi destinations look "dead" and write in-place, corrupting the accumulator.

**Full suite green:** Pkg.test 81,482 / 81,484 pass + 2 pre-existing broken (4m32s). Test count 81,398 → 81,482 (+84, exact match to file).

**Code change** (src/lower.jl ~939-1045):

- Lifted the iteration-LOCAL ctx construction OUT of the body-block loop and INTO the top of each iteration. The same `iter_ctx` is now reused for header_body dispatch (a1) AND body-block dispatch (b).
- Replaced the 4-type cascade with `_lower_inst!(iter_ctx, inst, hlabel)` per header non-phi inst.
- Hoisted `raw_cond_wire = resolve!(...)` to (a2), unconditional (was conditional on `!isempty(body_block_order)` pre-y986). Header-only loops (Collatz) pay the same single resolve they always did, just at a different point in the gate stream — empirically byte-identical.
- Body-block loop simplified: no per-block ctx rebuild, just per-block predicate computation + dispatch.

**Gotchas / Lessons:**

1. **LLVM aggressively closed-forms loops with constant-divisor body** — my first test fixture `(x ÷ UInt8(2))` accumulated K times produced `Block top: IRBinOp:add, IRBinOp:lshr, IRBinOp:mul | term=IRRet` — NO LOOP. The `_tabulate_auto_picks` heuristic also auto-routes small functions through 2^N lookup tables. Both bypass `lower_loop!` entirely. Hand-built ParsedIR (the `test_8p0g_parsed_ir_seam.jl` pattern) is the deterministic way to test specific lowering paths without depending on Julia codegen choices. Doc note: future loop-internals tests should default to hand-built fixtures for the "I want to exercise this exact dispatch path" cases.

2. **Do-while-K loop semantics are subtle.** With `i_next = i + 1` followed by `c = (i_next < n)` and the icmp at the END of the body, MUX-freeze on c=false means: iteration k commits IFF k < n. Effective committed iterations = `max(0, min(K, n) - 1)`. My first oracle was `min(K, n) * (x ÷ y)` and failed 9/15 — the `-1` matters. The lesson: write the oracle by tracing the CFG semantics, not by intuiting from the Julia source it would have come from.

3. **`_pick_add_strategy(:auto, …) → :ripple` post-U27 is the load-bearing empirical fact.** Without it, lifting from the 4-type cascade to `_lower_inst!`-with-`:ripple` would NOT be byte-identical for the fast-path types: the cascade calls `lower_binop!(gates, wa, vw, inst)` with NO kwargs (defaults: `add=:auto`, empty `ssa_liveness`, `inst_idx=0`) and `_lower_inst!` calls it with explicit `add=:ripple` + empty `ssa_liveness` + `inst_idx=ctx.inst_counter[]`. The `inst_idx` value only matters inside `_pick_add_strategy`'s `op2_dead` heuristic, and that heuristic is gated on `liveness_enabled = !isempty(ssa_liveness)` — which is `false` because `ssa_liveness` is empty. Net result: same `:ripple` path either way. The Collatz `14074/2320/8868` pin is the empirical witness; if a future agent restores per-iteration ssa_liveness threading or breaks the `:auto → :ripple` collapse, T3 trips.

4. **Hand-built `ParsedIR` inside a `using Bennett: ...` block needs `Bennett.IRInst[]` for the empty/typed instruction vector.** Just `[]` infers `Vector{Any}` which the IRBasicBlock constructor rejects. Same for the instruction list inside body blocks — must be `Bennett.IRInst[...]` to satisfy the type.

5. **`raw_cond_wire` hoist: byte-identical or not?** Pre-y986 the `resolve!(gates, wa, vw, term.cond, 1)` for header-only loops happened inside step (c). Post-y986 it happens at (a2), AFTER (a1) header_body lowering. The gate-emission ORDER between (a1) → (a2) → (c) is identical for header-only loops since (b) is empty; only the call-site moved. Empirically byte-identical (Collatz pin holds).

**Rejected alternatives:**

- **Option (b) hybrid (Proposer B's recommendation)** — would have kept the 4-type cascade + lazy fallback. Rejected after measuring that Option (a) is byte-identical for the fast-path types AND eliminates duplicated dispatch (CLAUDE.md §12). The "smaller blast radius" argument was overstated: every pinned baseline survives Option (a) intact.
- **Per-block iter_ctx rebuild (pre-y986 body-block pattern)** — kept around if header-body had been the only change, but lifting one level up and reusing is simpler. The shared `iter_ctx` sees `inst_counter[]` advance during header-body lowering, then keep advancing during body-block lowering — consistent with `lower_block_insts!`'s per-block monotonic counter usage, no observable behavior change.
- **LLVM-extracted-only test fixtures** — first attempt (`(x::UInt8, n::UInt8) -> a + (x ÷ 2)` accumulated) failed because LLVM closed-formed the loop AND the `_tabulate_auto_picks` heuristic took over. Second attempt with `strategy=:expression` + iter-dependent divisor still routed udiv through `lower_binop!` (the fast path), bypassing the bug. Switched to hand-built ParsedIR to deterministically place an IRCall in the header.

**Filed (follow-ups):** none. The fix is complete and the 84-assertion test file pins the dispatch contract going forward.

**Test count:** 81,398 → **81,482** (+84).

**Bd-tracked snapshot (post-y986 close):**

```
bd ready -n 200 | grep '\[bug\]' → 12 open [bug] beads (down from 13).
- P2: 25dm (blocked on z2dj IN_PROGRESS), ponm (bd-infra not Bennett.jl), cc0.5 (IN_PROGRESS).
- P3: jc0y, q04a, salb (closed earlier today), y56a, yys3, gboa, tpg0, ys0d, xiqt, d77b,
       qmk6, cklf, dq8l, heup, bjdg.
```

**Next agent — start here:**

1. Continue bugs-only per the chunk-045 directive. Two P2 closes today (salb, y986). Of the remaining 12 P3 bugs, suggested pickup order:
   - **`gboa`** (P3) — zero-ancilla in-place op dirty-bit hygiene; likely doc-only / assertion. Direct grind.
   - **`d77b`** (P3) — only 4 of 14 LLVM fcmp predicates implemented. Feature-shaped; verify whether documented scope cut or genuine bug.
   - **softfloat tier**: `tpg0` (`_sf_normalize_to_bit52` on m=0), `xiqt` (subnormal flush boundary), `ys0d` (`soft_exp` 0.9% off-by-1-ULP, `soft_exp_julia` already bit-exact). Each needs the §13 `subnormal-output range` testset.
   - **`y56a`** (P3) — triple-redundant integer division paths; investigation + dedup. Now easier: `_soft_udiv_compile` wrapper from salb gives the canonical kernel, so the redundancy can be measured and removed.
   - **`bjdg`** (P3) — ConstantFP/Poison/Undef in scalar operand → misleading error. Direct grind.
   - **`yys3`** (P3) — 200+ LOC manual 128-bit arithmetic to avoid `__udivti3` / `__umodti3`. Investigation-shaped.
   - **`q04a` / `jc0y`** (P3, both 3+1) — yesterday's filings; structural refactors of `_convert_instruction` Union return + `ReversibleCircuit.gates` storage layout. Pickup after the simpler defensive bugs.

2. **`y986` heads-up for any future loop-internals work:** the iteration-LOCAL ctx pattern at `lower.jl` ~970-985 is now the canonical entry point for ALL non-phi instruction dispatch inside `lower_loop!`. If you add a new IR type to `_lower_inst!`, it works automatically inside loops. Don't re-introduce a fast-path cascade.

3. **Hand-built `ParsedIR` is the right tool for testing specific lowering paths** when LLVM's IR-shape choices interfere. See the dual-track approach in `test/test_y986_loop_header_dispatch.jl` for a template.

### Branch state at session-end

`main @ <next commit>`, pushed and up to date with `origin/main`. Worklog: chunk 046 starts here (chunk 045 hit 283 lines after the salb entry).

### Bd-tracked snapshot

```
bd stats:
  Total Issues:   446
  Open:           117
  In Progress:    2     (Bennett-cc0.5 P2 bug — Julia TLS allocator
                         GEP base, T5-P6.3; Bennett-z2dj P2 task —
                         T5-P6 dispatcher; both pre-existing)
  Closed:         315   (salb + y986 today)
  Blocked:        0
  Ready to Work:  117
```
