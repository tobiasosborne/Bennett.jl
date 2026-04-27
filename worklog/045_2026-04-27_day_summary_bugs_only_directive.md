# Bennett.jl Work Log

## Session log — 2026-04-27 — Bennett-salb / U119 close (div-by-0 + signed typemin/-1 contract)

**Shipped:** see git log around the next commit; dual-function split for `soft_udiv` / `soft_urem` so the public API throws `DivideError` (matching `Base.div`) while the gate-inlined kernel stays branchless.

**Why:** Bennett-salb / U119 — `soft_udiv(a, 0)` silently returned `typemax(UInt64)`, `soft_urem(a, 0)` silently returned `a`, and `lower_divrem!` for signed `typemin/-1` silently wrapped to `typemin`. Native Julia raises `DivideError` in all three cases. Per CLAUDE.md §1, silent garbage is the wrong default.

**Design:** the kernel cannot throw — adding `iszero(b) && throw(DivideError())` would emit `@ijl_throw` (an external runtime call) into the kernel's LLVM IR, which `lower_call!` cannot extract (callees must be source-available). So the fix splits each function in two:

- Private `_soft_udiv_compile` / `_soft_urem_compile` — current branchless body, registered as the callee in `_CALLEES_INTEGER_DIV` and used as the callee in `lower_divrem!`. LLVM-poison-equivalent on `b == 0`: deterministic but unspecified output (`typemax` for udiv, dividend for urem).
- Public `soft_udiv` / `soft_urem` — thin wrapper, throws `DivideError` on `b == 0` and otherwise delegates. For direct Julia callers.

For signed `typemin ÷ -1` (handled at the `lower_divrem!` wrapper, not inside the kernel), the documented behaviour is the deterministic wrap to `typemin` — also LLVM-poison-equivalent. Matches the bead's "fail loudly OR produce LLVM-specified poison" clause.

**Test coverage:** `test/test_salb_div_by_zero.jl` (146 assertions / 6 testsets):
- `@test_throws DivideError` on the public API for 6 representative `a` values (each of udiv / urem).
- Positive correctness on the public API (b ≠ 0) — 6 a × 6 b = 72 each.
- `_compile` callees: documented poison-equivalent on b=0 (typemax / dividend); positive correctness on b ≠ 0.
- Compiled-circuit smoke: `(x::UInt8) ÷ (y::UInt8)` and `(x::UInt8) % (y::UInt8)` with `y=0` returns the documented poison value across `a`; `verify_reversibility` holds.
- Compiled-circuit smoke: `typemin(Int8) ÷ Int8(-1)` returns `typemin(Int8)`; `verify_reversibility` holds.

**Gate counts byte-identical** — the rename + wrapper is a pure refactor of the public surface. `test_gate_count_regression.jl` 39/39 unchanged. `test_division.jl` 4819/4819 unchanged (its tests pre-guard `b == 0` via ternary so don't hit the new throw). Full Pkg.test 81,398 / 81,400 pass + 2 pre-existing broken (4m20s).

**Mode:** direct grind. The change is purely a public-API split + documentation; the gate-emission path is untouched (just renamed). 3+1 protocol not invoked per the chunk-045 calibration ("defensive change → direct").

**Gotchas / Lessons:**

1. **Constant divisor `x ÷ Int8(0)` fails to compile with a misleading `BoundsError`** — separate from the silent-wrong-result bug fixed here. LLVM constant-folds the divisor at IR extraction, producing a poison/undef operand that `_convert_instruction` mishandles. This is bjdg-adjacent (ConstantFP/Poison/Undef in scalar operand → misleading error). Variable-divisor case (`(x, y) -> x ÷ y` with `y=0` only at sim time) is the one that exercises `lower_divrem!` and was the actual silent-garbage bug.

2. **Existing `test/test_division.jl:47` already documented the `typemin/-1` UB explicitly** (`# Edge cases (skip typemin/-1 which is UB: overflow)`). The bead was filed because the test author flagged the gap; this close converts "documented UB skipped in tests" → "documented poison-equivalent behaviour with explicit test asserting the deterministic value".

3. **Adding `throw` to a kernel breaks `lower_call!` extraction.** Confirmed empirically: `code_llvm(probe_udiv, …, optimize=false)` for a body containing `iszero(b) && throw(DivideError())` produces `call void @ijl_throw(ptr %jl_diverror_exception)` plus `unreachable` plus `@llvm.trap()`. The dual-function split is the right pattern for any future "kernel + safety wrapper" pair (cf. soft_fdiv, soft_fsqrt etc. — those don't throw because IEEE 754 has well-defined NaN/Inf semantics that don't need DivideError).

**Rejected alternatives:**

- **Single function with `iszero` short-circuit + `throw`** — would break `lower_call!` extraction, see gotcha #3 above. Empirically confirmed before writing the dual-function code.
- **Emit gate-level poison-detection wires in `lower_divrem!`** — would shift gate-count baselines (CLAUDE.md §6) and add ancilla; out of scope for the LLVM-poison-equivalent contract the bead allows. Could be a future "strict-mode" follow-up if a user actually wants runtime trap-on-poison; not filing because nobody has asked.
- **Renaming public `soft_udiv` rather than wrapping it** — discarded; `soft_udiv` is exported in `src/Bennett.jl:298` and matching `Base.div` semantics (throws on div-by-zero) is the right contract for the public name.

**Filed (follow-ups):** none. Bennett-bjdg (ConstantFP/Poison/Undef misleading error) already exists and covers the constant-divisor `BoundsError` observed in gotcha #1.

**Test count:** 81,252 → **81,398** (+146).

**Next agent — start here:** Continue bugs-only per the chunk-045 directive. With `salb` closed, remaining P3 bugs in suggested pickup order: `gboa` (zero-ancilla dirty-bit hygiene, likely doc-only), `d77b` (4 of 14 fcmp predicates implemented — feature-shaped, check if it's a documented scope cut), softfloat tier `tpg0` / `xiqt` / `ys0d` (each needs the §13 subnormal-output testset), `y56a` (triple-redundant integer division paths — investigation + dedup), then the heavyweight `y986` (3+1 required, will shift gate-count baselines for Collatz / soft_fdiv).

---

## Session log — 2026-04-27 — bugs-only grind: 8 closes (jepw + 59jj + p94b + fq8n + lgzx + ibz5 + t3j0 + 2yky)

**Shipped:** see git log around `f68b353..0330595` (10 code commits + bd-cache syncs).

| # | Bead | P | Type | Tests | Mode | What |
|---|---|---|---|---:|---|---|
| 1 | jepw | P2 | BUG | 168 | 3+1 | Diamond-in-body phi resolution. Per-iteration LOCAL `block_pred` / `branch_info` / `iter_preds` dicts inside `lower_loop!` + top-level `loop_body_labels` skip set. Unbroke `test_httg_loop_multiblock.jl` T3. |
| 2 | 59jj | P2 | BUG (partial) | 44 | direct | Typed `simulate(c, ::Type{T}, inputs)::T` overload. Filed Bennett-q04a (split `_convert_instruction` Union return) + Bennett-jc0y (gates storage layout) for the remaining valid cuts; documented `_gate_controls` + `tabulate.jl Vector{Any}` as STALE (already fixed prior). |
| 3 | p94b | P3 | BUG | 19 | direct | Predicate-machinery defensive asserts: distinct-predecessor check in `_compute_block_pred!`; width-1 invariant in both `_compute_block_pred!` and `_edge_predicate!`. |
| 4 | fq8n | P3 | BUG | 12 | direct | `lower_phi!` validates that every incoming SSA wire-vector has length == `inst.width`. (`resolve!` doesn't enforce widths for SSA operands.) |
| 5 | lgzx | P3 | BUG | 4 | direct | `_convert_instruction` store handler: replaced two silent `nothing` returns (non-integer value type, un-registered pointer) with `_ir_error` calls tagged `Bennett-lgzx`. Benign-intrinsic silent drops at line 1726 preserved. |
| 6 | ibz5 | P3 | BUG | 7 | direct | `resolve!` trip-wires the `OPAQUE_PTR_SENTINEL` by `op.name === :__opaque_ptr__` so the value=0 placeholder for unresolvable pointers does not silently materialise as integer 0. (`_operand_safe` is currently dead code; trip-wire is defensive against future wiring.) Companion icmp-folding half is already handled at `src/ir_extract.jl:2265`. |
| 7 | t3j0 | P3 | BUG | 12 | direct | `_expand_switches` rejects input blocks named with the reserved `_sw_*` prefix or equal to `:__unreachable__`. Catches accidental re-runs and crafted-input collisions. |
| 8 | 2yky | P3 | doc-only | 0 | direct | Investigated → **claims stale**: IRCall constructor already validates length + lower-bound; `lower_divrem!` does route through `_assert_arg_widths_match` via `lower_call!`. Tighter upper bound (`<=64`) prototyped and reverted because NTuple aggregate returns (e.g. 576-bit) are legitimately wider than 64. Decision recorded as comment in `src/ir_types.jl`. |

**Filed (follow-ups, post-jepw close):**
- Bennett-q04a (P3, 3+1) — split `_convert_instruction` 17-arm Union return into `_single` + `_expand!`.
- Bennett-jc0y (P3, 3+1) — `ReversibleCircuit.gates` storage layout (abstract `Vector{ReversibleGate}` → tagged-union or struct-of-arrays).

**Test count:** 80,985 → **81,252** (+267, including 1 broken→pass for httg T3).

**Why this distribution:** the directive in this same chunk mandated BUGS ONLY in suggested pickup order. P2 candidates: `25dm` (blocked on z2dj IN-PROGRESS), `59jj` (P2, partial — multi-cut), `ponm` (bd infra, not a Bennett.jl bug — `wisp_dependencies` table missing in the dolt store; verified live with `bd dep add` still failing). Then I worked the P3 list in directive order until stopping point.

**Gotchas / Lessons:**

1. **Diamond-in-body required reasoning about double-processed body blocks.** Body blocks of a loop appear in the function-level `topo_sort` AND inside `lower_loop!`'s K iterations — pre-jepw the top-level re-emission was harmless dead-gate emission (no consumer reads them). For diamond-in-body it would crash on the merge-block IRPhi against stale block_pred. Fix needed BOTH per-iteration LOCAL predicate dicts AND a top-level `loop_body_labels` skip set; one without the other doesn't work.

2. **Bead claims go stale at the line-number level AND the architectural level.** Multiple beads cited specific line numbers that no longer matched (t3j0 cited 1014/1209-1210; ibz5 cited 1760/1915-1957; fq8n cited 1137 — all stale). Two beads' core claims were largely or fully superseded (59jj's `_gate_controls` + Vector{Any}; 2yky's `_assert_arg_widths_match` route). Always live-measure before designing the fix.

3. **"Investigated, doc-only" is the correct disposition for stale beads.** Pattern: 2yky, similar to 3of2 / vt0a yesterday. Better than leaving the bead open OR shipping a fix that doesn't address a real problem. The doc-only commit + comment-in-source records the "tested-and-rejected" decision so future maintainers don't re-walk.

4. **"Defensive direct-grind vs. algorithmic 3+1" calibration:** assertion-only changes don't need 3+1 (p94b, fq8n, lgzx, ibz5, t3j0). Anything algorithmic in `lower.jl` / `ir_extract.jl` does (jepw used 3+1; y986 will need it; q04a + jc0y will need it). Still need to be honest about which mode you're in — the comment block in `src/ir_types.jl` for 2yky is an example of "defensive but with side-effects" → reverted to pure doc-only.

5. **Aggregate widths > 64 are legitimate in IRCall.** NTuple{9,UInt64} sret returns 576-bit `ret_width`. The `[1, 64]` width contract from Bennett-zmw3 / U111 applies ONLY to the SCALAR `:const` path inside `resolve!`. Do not propagate that bound elsewhere without measuring.

6. **WSL OOM scare during the grind — investigated and verified NOT a project regression.** Measured peaks: `using Bennett` 1.87 GB (cold precompile), single test 1.83 GB, full Pkg.test() 1.06 GB. WSL has 60+ GB. The earlier crash (exit 137) was external pressure: rapid back-to-back `julia --project` invocations + browser/IDE workloads sharing WSL's pool. Bennett.jl's full suite is well-behaved.

**Rejected alternatives:**

- **2yky upper-bound check (`arg_widths[i] <= 64`)** — broke `test_atf4_lower_call_nontrivial_args.jl` T2 (NTuple{9,UInt64} ret_width=576). Reverted; comment in `src/ir_types.jl` records the decision.
- **lgzx test using `define void @...`** — float store inside void-returning function failed extraction earlier (VoidType width query) before reaching the new error path. Switched test fixtures to `define i32` to bypass the upstream error and exercise my code.
- **Skipping body blocks at top-level via `_lower_inst!` no-op (option iii from the jepw 3+1 design)** — too fragile; `loop_body_labels` skip set (option ii) was clearer.

**Next agent — start here:**

1. **Continue bugs-only.** Per `bd ready -n 200 | grep '\[bug\]'`, **13 open `[bug]` beads** remain (down from 24 at session start; 8 closed + 2 follow-ups filed + 3 deltas elsewhere). Suggested next pickups in priority order:
   - **Bennett-y986** (P3) — `lower_loop!` header-body 4-type cascade still drops non-arith IR types (IRCall, IRStore, IRLoad). **Heads-up**: I deliberately preserved this cascade during jepw because dispatching through `_lower_inst!` would alter Collatz / soft_fdiv gate-count baselines. Will need 3+1 protocol per CLAUDE.md §2 AND careful baseline analysis. Don't direct-grind it.
   - **Bennett-salb** (P3) — `typemin ÷ -1` silent wrap, `x ÷ 0` impl-defined garbage. Defensive — direct grind.
   - **Bennett-y56a** (P3) — triple-redundant integer division paths (lower_binop / soft_udiv / unregistered callee). Likely investigation + dedup.
   - **Bennett-gboa** (P3) — zero-ancilla in-place ops dirty-bit hygiene. Likely doc-only.
   - **Bennett-d77b** (P3) — only 4 of 14 LLVM fcmp predicates implemented. Feature-shaped; check if it's actually a bug or a documented scope cut.
   - softfloat tier (`tpg0`, `xiqt`, `ys0d`) — bit-exactness fixes against `Base.<func>`. Per CLAUDE.md §13, every transcendental needs a `subnormal-output range` testset; mirror the `soft_exp` pattern at `test/test_softfexp.jl:135`.
   - **Bennett-yys3** (P3) — 200+ LOC manual 128-bit arithmetic to avoid `__udivti3` / `__umodti3`. Investigation-shaped.

2. **P2 status:**
   - `25dm` still blocked on `z2dj` IN-PROGRESS. Drive z2dj forward (T5-P6 dispatcher arm, 3+1 per CLAUDE.md §2, full plan in `docs/design/p6_consensus.md`) to unblock.
   - `ponm` is a beads-tool schema migration, NOT a Bennett.jl code bug. `bd dep add` still fails with "table not found: wisp_dependencies". Out of session scope.

3. **Bug vs cosmetic ratio (snapshot 2026-04-27 mid-session):**
   - Total beads: 446 / closed 313 / open 119 / in-progress 2 (`z2dj` task, `cc0.5` P2 bug — both pre-existing) / blocked 0.
   - 13 open + 1 in-progress = **14 [bug] beads unfinished** out of 121 (119 open + 2 in-progress) — **~11.5% bugs, ~88.5% non-bugs** (refactors, docs, polish, structural, features). Roughly aligned with the prior chunk's "15% serious / 85% cosmetic" estimate. The bug fraction is small enough that the bugs-only directive remains the right focus until the genuine-defect tail is exhausted.
   - Of the 14 bugs: **3 P2** (`25dm` blocked on z2dj; `ponm` is bd-tool infra not Bennett.jl; `cc0.5` IN_PROGRESS — Julia TLS allocator GEP base, T5-P6.3) and **11 P3**.

4. **Follow-ups filed during this session needing 3+1:** Bennett-q04a, Bennett-jc0y. Both are P3 — pickup after the simpler defensive bugs above are exhausted, since each will take a full 3+1 cycle.

5. **Memory note for the directive:** WSL OOM during this grind was external. Bennett.jl's full suite peaks at ~1 GB; do not investigate the project unless a future test file genuinely exceeds 4 GB RSS under measurement.

### Branch state at session-end

`main @ 0330595`, pushed and up to date with `origin/main`. Working tree clean modulo `prompts` (untracked, pre-existing — not created by this session).

### Bd-tracked snapshot (2026-04-27 mid-session)

```
bd stats:
  Total Issues:   446
  Open:           119
  In Progress:    2     (Bennett-cc0.5 P2 bug — Julia TLS allocator
                         GEP base, T5-P6.3; Bennett-z2dj P2 task —
                         T5-P6 dispatcher; both pre-existing)
  Closed:         313
  Blocked:        0
  Ready to Work:  119
```

---

## Session log — 2026-04-27 — Bennett-jepw / U05-followup close (diamond-in-body phi resolution)

**Shipped:** see git log around `f68b353`; per-iteration LOCAL `block_pred` / `branch_info` / `preds` dicts inside `lower_loop!` so an IRPhi at a body-block merge resolves via `_edge_predicate!`. Top-level pass skips `loop_body_labels` to preempt redundant body-block re-dispatch.

**Why:** The U05 MVP (Bennett-httg) explicitly deferred per-block predicate computation for diamond-CFG inside loop bodies (chicken-and-egg: `_compute_block_pred!` wanted `branch_info[hlabel]` populated before body blocks were lowered, but the old flow only computed exit-cond at step (c) AFTER body blocks). jepw was the largest open compiler bug per the 2026-04-27 directive.

**Gotchas / Lessons:**

1. **Body blocks are double-processed in the pre-jepw flow.** They appear in the function-level topo order (their forward edges aren't back-edges) AND inside `lower_loop!`. The existing T1/T2/T4 tests pass because the redundant top-level emission writes to dead wires (no consumer reads them — the IRRet at the exit block already saw the MUX-frozen phi). For jepw to land, this redundant pass had to be removed (option (ii) — `loop_body_labels` skip set), or it would crash on the merge block's IRPhi against a stale `block_pred`. T1 K=3 dropped 824→552 gates as a side-effect of the skip — correctness unchanged, T2 monotonicity still holds. T1/T2/T4 in `test_httg_loop_multiblock.jl` and Collatz in `test_loop_explicit.jl` all green; gate-count regression baselines (`test_gate_count_regression.jl`, 39/39) byte-identical.

2. **`_compute_block_pred!` silently skips predecessors with no `block_pred[p]`** (line 1025 `# skip if predecessor has no predicate (loop)`). Per-iteration LOCAL dicts work because each body block's predecessors (header or earlier body blocks in topo order) ARE in `iter_block_pred` by the time `_compute_block_pred!` is called for it.

3. **Reusing `raw_cond_wire` for both `branch_info[hlabel]` AND `exit_cond_wire`** (with polarity NOT applied via `lower_not1!` if `!exit_on_true`) avoids duplicate `resolve!(term.cond)` calls. Saves one icmp re-evaluation per iteration.

4. **`!isempty(body_block_order)` gating preserves Collatz / soft_fdiv byte-identical.** Header-only loops fall through to the original `resolve!(term.cond)` at step (c). The `iter_*` dicts are only constructed when there's actual diamond work to do.

5. **`@test_broken` flips on a real fix**: T3 in `test_httg_loop_multiblock.jl` was `@test_broken try ... catch false end`. Once the fix made the body return `true`, `@test_broken` itself errored. Replaced with a regular `@test all(...)` smoke check; full coverage moved to the new `test_jepw_diamond_in_body.jl` (3 diamond shapes × exhaustive Julia-oracle sweep × `verify_reversibility`, 168 assertions).

**Rejected alternatives:**

- **Approach (b) inline AND-chains** via `_and_wire!` would have duplicated `_compute_block_pred!` logic and risked drift with the function-level pass.
- **Approach (c) defer with hard error** would have failed the test contract — diamond-in-body needed to actually compile.
- **Mutating the function-level `block_pred` with body-block entries** (proposer B's first sketch, replaced) was incoherent: each iteration produces fresh wires for the same SSA labels, so the function-level dict could only see the last iteration's view — useless to any consumer.

**Next agent starts here:** Continue the bugs-only grind. Remaining P2 bugs: `25dm` (blocked on z2dj IN-PROGRESS — drive z2dj forward to unblock), `59jj` (type instability in hot paths — multi-cut, 3+1 for storage layout), `ponm` (bd infra — `wisp_dependencies` table missing). P3 bugs: `p94b`, `fq8n`, `lgzx`, `ibz5`, `t3j0`, `2yky`, `y986`, `salb`, `y56a`, `yys3`, `gboa`, `tpg0`, `ys0d`, `xiqt`, `d77b`, etc. Always pair `verify_reversibility` with output-vs-Julia-oracle assertions.

---

## Session log — 2026-04-27 — DAY SUMMARY for 2026-04-26/27 grind + STRICT NEXT-AGENT DIRECTIVE (BUGS ONLY)

### 🚨 NEXT AGENT — READ THIS FIRST 🚨

**You are to work on BUGS ONLY. No exceptions.**

The catalogue has 24 open `[bug]` beads. That is the ONLY work allowed in your session. Specifically:

- **DO NOT** pick refactors, renames, file reorganisations, docstring polish, dead-store cleanups, error-monoculture rewrites, naming-convention fixes, or any cosmetic / structural improvement.
- **DO NOT** file new "follow-up" beads as a substitute for fixing a real bug. If you spot a follow-up worth filing, file it AFTER you've shipped a real bug fix (one bug close minimum per session).
- **DO NOT** procrastinate on hard bugs by picking easier non-bug items. The hard bugs (jepw, 25dm, p94b, fq8n, lgzx, ibz5) have been deferred enough.
- **DO NOT** use "not enough runway" as an excuse. The 3+1 protocol is fast (~2 min per proposer in parallel). Multi-session work is fine — start it, ship a coherent slice, write up the handoff.
- **DO NOT** say "this needs more investigation" without ALSO doing the investigation IN this session. Investigation IS work — close the bead as `investigated, doc-only` if the conclusion is "out of scope, foundational follow-up filed" (see Bennett-3of2 / vt0a today for the template).
- **DO NOT** complain about scope, complexity, the 3+1 trip-wire, or "this would be cleaner as a refactor." Fix the bug.

**The bug list (P2 → P3, in suggested pickup order):**

| Bead | P | Sites | Why now |
|---|---|---|---|
| **jepw** | P2 | `lower.jl` loop unroller | Diamond-in-body phi resolution; needs 3+1; **biggest open bug**; deferred since chunk 043 |
| **25dm** | P2 | `test/test_t5_corpus_*.jl` | T5 multi-lang corpus is `@test_throws` — promised but not delivered; gated on z2dj IN-PROGRESS — drive z2dj forward, don't sit on it |
| **59jj** | P2 | `lower.jl` hot paths | Boxed returns, `Vector{Any}` — type instability — measured perf hit |
| **ponm** | P2 | bd infra | `wisp_dependencies` table missing; affects bd dep tracking; this IS infrastructure but it's tagged `[bug]` — fix |
| **p94b** | P3 | `lower.jl:876-893` | `_compute_block_pred!` OR-folds without mutex assert; CLAUDE.md phi-resolution false-path-sensitisation risk |
| **fq8n** | P3 | `lower.jl` | phi with 0 incoming / mixed widths not validated |
| **lgzx** | P3 | `lower.jl` | `_convert_instruction` result-type filter silently drops stores |
| **ibz5** | P3 | `lower.jl` | OPAQUE_PTR_SENTINEL compiled as zero; ptr icmp loses provenance |
| **t3j0** | P3 | `lower.jl` | `_expand_switches` synthetic labels collide on re-run |
| **2yky** | P3 | `lower.jl` | IRCall arg_widths invariant unchecked |
| **y986** | P3 | `lower.jl` | loop_unroller header-body drops non-arith IR types |
| **salb** | P3 | `lower.jl` | typemin ÷ -1 silently wraps; x ÷ 0 returns garbage |
| **y56a** | P3 | `lower.jl`, `divider.jl` | triple-redundant integer division paths |
| **yys3** | P3 | `softfloat/` | 200+ LOC manual 128-bit arithmetic to avoid `__udivti3` |
| **gboa** | P3 | `lower.jl` | Zero-ancilla in-place ops dirty-bit hygiene undocumented |
| **tpg0** | P3 | `softfloat/` | `_sf_normalize_to_bit52` pathological on m=0 |
| **ys0d** | P3 | `softfloat/fexp.jl` | soft_exp off-by-1-ULP ~0.9% vs Base.exp; soft_exp_julia is bit-exact — fix soft_exp or document deprecation |
| **xiqt** | P3 | `softfloat/` | `_sf_handle_subnormal` flush-to-zero boundary may drop round-up case |
| **d77b** | P3 | `softfloat/fcmp.jl` | Only 4 of 14 LLVM fcmp predicates implemented |

24 [bug] beads total open. (Some additional bugs not enumerated above; run `bd ready -n 200 \| grep '\[bug\]'` to see the full list.)

**Workflow per bug** (fixed by today's grind through 6 closes):

1. `bd update <id> --claim`
2. `bd show <id>` — read claim + sites
3. **MEASURE the actual current behaviour BEFORE designing a fix.** The bead's headline numbers may be stale (today's 5qrn was claimed as "x+0 → 98 gates" — actual was 86; 3of2's "279k wire bloat from this leak" — actual contribution <0.1%).
4. If it touches `lower.jl` / `ir_extract.jl` / `bennett_transform.jl` / `gates.jl` / `ir_types.jl` / phi resolution: **3+1 protocol.** Two `Plan` agents in parallel with full prompt context (CLAUDE.md, the relevant code, the bead, the catalogue entry, the source-report finding). Synthesize. Implement.
5. If it's a defensive cleanup (assertions, mask refactor, doc): **direct grind** — no proposers needed. Be honest about which mode you're in.
6. **`verify_reversibility` is NOT a semantic check.** Pair every test with an output assertion against a Julia-native oracle. Today's 3of2 attempt passed `verify_reversibility` while producing sign-flipped sdiv results — that test pattern would have caught it on the first sweep.
7. Test, commit, close, worklog entry, push. Worklog entry should follow today's pattern: shipped / why / gotchas-and-lessons / rejected-alternatives / next-agent-starts-here.

**If you have time after one bug close**: pick another bug. Repeat. Do not pick non-bug items.

---

### Day summary — 2026-04-26 + early 2026-04-27

**Closes (chronological)**:

| Bead | P | Type | What |
|---|---|---|---|
| ardf | P3 | BUG | fdiv overflow_result discard + bit-exact NaN tests |
| 9c4o | P3 | task | Include reorder so lower.jl deps load first |
| kcxv | P3 | task | Already-fixed-by cs2f; 30s triage close |
| op6a | P3 | BUG | Cuccaro docstring gate counts corrected |
| b2fs | P3 | task | tabulate `Any[]` → `Tuple` (16M-row hot path) |
| g0jb | P3 | BUG | asw2 flake fix (n_tests 4 → 20) |
| 5kio | P3 | task | sizehint! across arithmetic kernels |
| **doh6** + **5ec** | P3 | task | docs/make.jl + Documenter wiring (vision-blocking) |
| **5qrn** | **P2** | **BUG** | Trivial-identity peepholes — x*1 692 → 26 gates (26.6×) |
| **qcso** | **P2** | **FEATURE** | compose(c1, c2) — Sturm vision unblocker |
| **zmw3** | P3 | BUG | Shift bounds + resolve! mask robustness (17-session-procrastinated) |
| **3of2** | P3 | BUG | Investigated → doc-only; vt0a filed for foundational fix |

**Filings** (drive-by follow-ups): 7xng (constant_wires dead store), 1xub (BENCHMARKS refresh post-5qrn), vt0a (Bennett-aware free!).

**Pkg.test growth**: 73,068 → 80,985 (+7,917 assertions). 12 new test files.

**Headline learnings**:

1. **`verify_reversibility` ≠ semantic correctness.** It checks ancilla-zero + input-preservation. Output correctness must be asserted separately against a Julia-native oracle. The 3of2 fix attempt would have shipped silently wrong without this discipline.

2. **3+1 protocol is the right tool for compiler-internals.** Used twice today (5qrn, qcso) — both saw strong proposer convergence and surfaced subtle issues my prompt context had missed (5qrn's stale baseline numbers, qcso's wire-budget compaction). Cost: ~2 min per proposer in parallel. Synthesis: ~5 min. Worth it for any change to `lower.jl` / `ir_extract.jl` / `bennett_transform.jl` / `gates.jl` / `ir_types.jl`.

3. **Direct grind is fine for defensive cleanups.** 3+1 was skipped for zmw3 (assertions + mask refactor — non-algorithmic). Decision recorded so future sessions can use the same calibration: "Algorithmic change → 3+1; defensive change → direct."

4. **Bead-claim numbers go stale.** Always live-measure before designing the fix. 5qrn's "x+0 → 98 gates" claim was actually 86; 3of2's "279k wire bloat from this leak" was actually <0.1% contribution.

5. **`free!()` is incompatible with Bennett's outer reverse pass at the lower_*.jl layer.** Existing `free!` users (feistel, qrom, pebbled_groups) work because they're inside self-contained sub-circuits. At the lower_divrem! / lower_call! interface, reuse crosses Bennett-construction boundaries. See Bennett-vt0a for the foundational fix.

6. **"investigated, doc-only" close is a legitimate disposition.** Updates the source docstring with the analysis + files a foundational follow-up bead. Better than silently leaving the issue OR shipping a broken "fix" that passes verify_reversibility but is semantically wrong.

**Catalogue health snapshot at session-end** (2026-04-27 ~early morning):

- Total beads: 444 / closed 305 / open 125 / blocked 0
- P2: 16 open (4 BUGs)
- P3: 90 open (~18 BUGs)
- P4: 19 open (mostly non-bug)
- 24 [bug] beads total open
- 0 P0/P1 (critical) bugs — project is HEALTHY
- 15% of open backlog is "serious"; 85% is "cosmetic" / refactor / polish

**Vision integration status**: `controlled` ✓, `compose` ✓ (today), `Float64` / soft-float ✓, jldoctest infra ✓ (today). **Remaining for Sturm `when(qubit) do f(x) end`**: 25dm (multi-language ingest — promised but not delivered).

---

### Branch state at session-end

`8c127ae` on main, pushed and verified `up to date with 'origin/main'`. Worklog: chunk 044 hit 282 lines (over the 280 cap); **this entry starts chunk 045**.

### Bd-tracked beads (snapshot)

```
bd stats:
  Total Issues:   444
  Open:           125
  In Progress:    1     (z2dj)
  Closed:         305
  Ready to Work:  125
```
