# Bennett.jl Work Log

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
