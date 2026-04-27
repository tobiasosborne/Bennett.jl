# Bennett.jl Work Log

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
