# Bennett.jl Work Log

## Session log — 2026-04-27 (3+1 refactor, stage 1) — Bennett-tzrs partial (extract _handle_intrinsic)

**Shipped:** commit 904fe4d. First slice of Bennett-tzrs / U41 — 270-line LLVM-intrinsic prefix block lifted out of `_convert_instruction`'s 836-line body into a dedicated `_handle_intrinsic(cname, inst, names, counter, dest, ops)` helper. Bead REMAINS OPEN; stages 2-5 deferred.

**Why:** Bennett-tzrs / U41 is a P2 structural task. CLAUDE.md §2 mandates 3+1 protocol for any change to ir_extract.jl. Spawned 2 `Plan` proposers in parallel.

**3+1 outcome:**

- **Proposer A** → `Dict{LLVM.API.LLVMOpcode, Function}` dispatch keyed off the opcode int. Argued: single hash + cmp per call, table-driven clarity. Identified `_handle_call` as a single function (intrinsic table + callee registry + benign allowlist all in one — the benign-allowlist is a fail-loud guard, not a peer arm).

- **Proposer B** → `if/elseif` over named helpers, NOT a Dict. Argued: the q04a contract test pins a 200 KiB allocation cap on `extract_parsed_ir`; a `Dict{_, Function}` adds hash + cmp + boxed Function values that risk regressing that bound. Julia's union-splitting on a typed `if/elseif` jump table preserves type stability that Dict-as-dispatch loses. Also argued for "minimum viable first commit" = intrinsic block ONLY (~270 LOC moved, 14 distinct prefix branches).

- **Synthesis (the +1, orchestrator):**
  - **Mechanism: B wins.** The 200 KiB allocation cap is a real constraint. Plus CLAUDE.md §11 favors plain functions over Dict-as-dispatch when both work.
  - **Granularity: B wins.** "Minimum viable first commit" matches CLAUDE.md §8 ("get feedback fast — every 50 lines, not 500").
  - **Vector twin: both reject unification.** Sharing helpers, not dispatchers.
  - **All extractions stay in src/ir_extract.jl** (preserves cc0.x catch's `occursin("ir_extract.jl:", msg)` heuristic).

**Implementation:** `_handle_intrinsic` placed immediately above `_convert_instruction`. The original 270-line block in the call arm replaced with a 2-line dispatch:

```julia
handled = _handle_intrinsic(cname, inst, names, counter, dest, ops)
handled === nothing || return handled
```

Order of `if startswith(cname, ...)` branches preserved exactly — load-bearing because `llvm.minnum` / `llvm.minimum` (and `maxnum` / `maximum`) share handlers via prefix-match, and the floor/ceil/trunc/rint/round branch is intentionally a no-op (registered-callee path picks up `soft_floor` / `soft_ceil` / etc.).

**Verified canaries (per Proposer B's "after each handler extraction" sequence):**

- `test/test_gate_count_regression.jl` — 39/39 byte-identical baselines.
- `test/test_q04a_convert_instruction_contract.jl` — 9/9 (Union arm count in [10, 22], caller dispatch shape pinned, 200 KiB allocation cap intact).
- Full Pkg.test — 84,352 / 84,354 (same count as pre-extraction; 2 pre-existing broken; 3m59s).

**Stages 2-5 (DEFERRED):** the remaining arms in `_convert_instruction` are:

- Stage 2 candidates (binop / icmp / select / phi / div_rem / cast / branch): each is **6-11 LOC** in body. The bead asks for "handlers ~10-20 LOC"; these are already AT or BELOW that target. Wrapping each in a named function adds ~5 LOC signature/end overhead per arm vs ~6-11 LOC body — a 50-80% overhead ratio.
- Stage 3-5 (terminators / memory / casts): mostly 10-30 LOC; closer to the bead's target but still mechanical.

Per CLAUDE.md §11 ("Don't add abstractions beyond what the task requires"), stopping at stage 1 is the right call: the BIG win was the 270-line intrinsic block, not the 6-11 LOC per-arm extractions. If a future bug class concentrates in one of those arms, the 3+1 protocol can be re-invoked then with concrete evidence.

**Gotchas / Lessons:**

1. **`LLVM.operands(inst)` returns `LLVM.UserOperandSet`, not `Vector`.** First attempt at `_handle_intrinsic`'s signature used `ops::Vector` — Julia raised `MethodError: no method matching` immediately on first compile. Loosened to untyped `ops` (since the body just indexes `ops[1]`, `ops[2]`, etc., which UserOperandSet supports). Lesson: when extracting helpers from a function that calls into LLVM.jl, leave operand-set parameters untyped unless you've verified the concrete return type of `LLVM.operands(...)`.

2. **`if` doesn't create scope in Julia.** The call arm has TWO consecutive `if n_ops >= 1` blocks. The first declares `cname`; the second uses it. This works because both are inside the same outer function scope. Almost-broke this when I considered putting `_handle_intrinsic` inline as `cname = ...; result = if startswith(...) ... end`; the original two-`if` shape preserves the scoping correctly post-extraction.

3. **Sed-based block replacement requires careful boundary identification.** Used `sed -i '1707,1975c\...'` to replace 269 lines with a 2-line call site. Lesson: always `cp` the file to /tmp first as a safety net before any sed in-place edit. The pre-edit copy at /tmp/ir_extract_pre_tzrs.jl was the bisect anchor when the first smoke run failed (`MethodError: no method matching _handle_intrinsic`); diffing revealed the type-annotation issue immediately.

4. **OOM kill mid-Pkg.test was external.** First Pkg.test run died with exit 137 (SIGKILL by oom-killer) at the precompile step. Second run completed in 3m59s with the same code. Per the chunk-045 lesson (WSL OOM scare): Bennett.jl's full suite peaks ~1 GB; do not investigate the project unless a future test file genuinely exceeds 4 GB RSS. The kill was external pressure (concurrent Julia test runs from other shells).

**Rejected alternatives:**

- **Stage 2-5 in this session** — diminishing returns per CLAUDE.md §11. The 6-11 LOC arms don't benefit from extraction.
- **Dict{Opcode, Function} dispatch (Proposer A's mechanism)** — risks regressing the 200 KiB allocation cap.
- **Move handlers to a new file (e.g. `ir_extract_handlers.jl`)** — would break the cc0.x catch's `occursin("ir_extract.jl:", msg)` benign-error heuristic. Both proposers identified this risk.
- **Unify scalar+vector dispatchers** — both proposers rejected: forces every handler to branch on vector-vs-scalar internally; the existing `_safe_is_vector_type(inst)` early-out is a clean seam.

**Filed (follow-ups):** none. Bead remains open with notes recording stage-1 completion + stage-2-5 deferral rationale.

**Test count:** 84,352 → **84,352** (unchanged — pure structural extraction).

---

## Session log — 2026-04-27 (LOC tier, big delete) — Bennett-tbm6 close (Karatsuba multiplier removed)

**Shipped:** see git log around the next commit. Karatsuba multiplier deleted across 7 source/doc files: ~250 LOC net removal.

**Why:** Bennett-tbm6 — Karatsuba was empirically vestigial at every supported width. The bead's measured table (post-U27 ripple-add defaults):

| W   | schoolbook Toff | karatsuba Toff | k:s ratio |
|-----|----------------:|---------------:|-----------|
|   8 |             144 |            502 | 3.49 |
|  16 |             664 |           2000 | 3.01 |
|  32 |            2856 |           6960 | 2.44 |
|  64 |           11848 |          22658 | 1.91 |

The trend is consistent with O(W^log₂3) vs O(W²) asymptotics but ratio never crossed 1 — the asymptotic crossover sits past W=128, beyond what `ir_extract` lowers today (Int128 sret unsupported). The path was a maintenance liability with zero practical wins.

**Mode:** direct grind, Option (C) per the bead's prescription (full removal vs salvage / lift W=128 ceiling / deprecation-warn). Per CLAUDE.md §11 ("don't add abstractions beyond what the task requires"), salvage was wrong: there's no caller demand and the underlying algorithm has known wire-cost asymptotic problems (Θ(W^log₂5)) that won't go away.

**Sites touched:**

- `src/multiplier.jl`: deleted `lower_mul_karatsuba!` + `_karatsuba_wide!` (~140 LOC) + the 60-line cost-tradeoff docstring. Replaced with a 7-line removal note citing tbm6.
- `src/lower.jl`: removed `use_karatsuba::Bool` field from `LoweringCtx`, deleted the three dead 11/12/13-arg backward-compat `LoweringCtx` constructors (~33 LOC; no internal call site used them — both internal callers pass the full positional list), removed `use_karatsuba` kwarg from `lower()`, `lower_block_insts!`, `lower_loop!`, `lower_binop!`, and the `_lower_inst!(::IRBinOp)` dispatch. Simplified `_pick_mul_strategy` to drop the `use_karatsuba::Bool` arg and the `:karatsuba` return arm. Strategy validation error message now lists `:auto, :shift_add, :qcla_tree` and explicitly cites tbm6 for `:karatsuba` removal.
- `test/test_karatsuba.jl`: deleted (orphan — was never registered in runtests.jl).
- `benchmark/bc6_mul_strategies.jl`: deleted.
- `test/test_mul_dispatcher.jl`: replaced the `:karatsuba forces Karatsuba` positive testset (4×3 simulate cross-product + verify = 13 assertions) with a single `@test_throws` checking that `:karatsuba` is now rejected.
- `test/test_4fri_mul_target.jl` + `test/test_5qrn_identity_peepholes.jl`: cleaned up `:karatsuba` mentions in headers / comments.
- `docs/src/api.md`: removed `:karatsuba` from the `mul=` strategy menu + cited tbm6.
- `docs/src/tutorial.md`: removed the "Gate-count at W ≥ 32 → :karatsuba" recommendation row + the bc6 benchmark reference; cited tbm6.

**Test count:** 84,364 → **84,352** (-12 from the test_mul_dispatcher.jl shrink: 13 cross-product assertions → 1 @test_throws).

**Adjacent cleanup (drive-by, partial ehoa):** the three dead `LoweringCtx` backward-compat constructors at the previous lines 112-145 were also removed. Both internal call sites (`lower_block_insts!` ~717, `lower_loop!` ~1003) pass the full positional argument list; the compat shims had zero remaining callers post-tbm6. This closes the `LoweringCtx has 4 back-compat constructors` half of Bennett-ehoa (the `::Any` field concretization half remains; that needs 3+1 per CLAUDE.md §2).

**Gotchas / Lessons:**

1. **`use_karatsuba::Bool` was a thread-through, not a strategy selector.** The struct field, the kwarg in `lower()`, and the kwarg in `lower_binop!` formed an indirect path: `lower()` → `lower_block_insts!`(kwarg) → `LoweringCtx`(field) → `_lower_inst!(::IRBinOp)` → `lower_binop!`(kwarg) → `_pick_mul_strategy(use_karatsuba=...)`. AND there was an explicit `mul=:karatsuba` selector. So Karatsuba could be selected EITHER by `lower(use_karatsuba=true)` OR by `lower(mul=:karatsuba)`. Removing both paths required tracing through every layer, but each layer was mechanical once identified. Lesson: when a feature has both a "smart pick" flag AND an explicit selector, removing it requires walking BOTH paths AND verifying neither is referenced from public docs / tutorials / external callers.

2. **Orphan test files exist.** `test/test_karatsuba.jl` was a 56-line file with hand-written assertions that never appeared in `runtests.jl`. Was probably included via a deleted include() at some point; the orphan persisted. CLAUDE.md §11 "don't keep dead code" — files in `test/` not registered in runtests.jl are dead code by definition.

3. **Public docs lag source code.** `docs/src/api.md` and `docs/src/tutorial.md` both still listed `:karatsuba` as a recommended strategy AND referenced `benchmark/bc6_mul_strategies.jl`. The `mul=` kwarg in the public API surface flows through to the docstrings, so removing a strategy requires sweeping ALL doc references — not just the implementation. `grep -rn "karatsuba" docs/` is the canonical check.

**Rejected alternatives:**

- **Option (D) deprecation warning** — would have left ~150 LOC in place plus added a `@warn` + a deprecation-period commitment. CLAUDE.md "avoid backwards-compat hacks". Direct removal is cleaner for vestigial-with-zero-callers code.
- **Option (B) lift W=128 ceiling first** — requires Int128 sret support in `ir_extract.jl`, which is a separate substantial effort. The crossover is hypothetical until measured at W=128+; removing now and resurrecting from the bead's commit history is cleaner than carrying dead code.
- **Option (A) audit impl for waste** — even with optimistic 50% reduction, Karatsuba would still be 1.0-1.7× WORSE than schoolbook at supported widths. Not worth the audit.

**Filed (follow-ups):** none. The `LoweringCtx::Any` concretization half of `Bennett-ehoa` remains open (3+1 protocol required per CLAUDE.md §2).

---

## Session log — 2026-04-27 (post-bugs grind, ergonomics tier) — Bennett-cvnb close (bennett_direct + self_reversing discoverability)

**Shipped:** see git log around the next commit; new `bennett_direct(lr)` convenience entry point at src/bennett_transform.jl + `bennett()` docstring expansion + README "Pre-reversed primitives" callout rewrite + test/test_cvnb_bennett_direct.jl (18 assertions / 4 testsets) registered in runtests.jl.

**Why:** Bennett-cvnb / Sturm.jl-ao1 — Sturm.jl downstream users (Session 74 worklog) couldn't find the existing `self_reversing=true` fast path from the README. Result: their `qrom_lookup_xor!` constructed `LoweringResult` via the (then) 7-arg constructor that defaulted `self_reversing=false`, getting the full Bennett wrap (4× Toffoli, +6 ancillae) instead of the forward-only short-circuit. Discoverability bug: the mechanism existed; the API/docs didn't surface it.

**Mode:** direct grind, ergonomics-only (no behavior change to existing callers). The new `bennett_direct` is a thin assertion + delegation; CLAUDE.md §2 3+1 trip-wire is for behavior-changing pipeline edits.

**Net change:**
- `src/bennett_transform.jl`: bennett() docstring gains a "Pre-reversed primitives" section with the 8-arg constructor pattern + tabulate.jl citation. New `bennett_direct(lr)` function asserts `lr.self_reversing == true` (raises ArgumentError with a precise message naming the 8-arg constructor + `bennett(lr)` fallback otherwise) and delegates.
- `README.md`: self_reversing section rewrites the previous 5-line note into a downstream-author-targeted callout with the explicit 8-arg constructor recipe + `bennett_direct` example + Sturm.jl impact (peak qubits 28 → ~22 on N=15 Shor mulmod).
- `test/test_cvnb_bennett_direct.jl`: 18 assertions / 4 testsets — byte-identical to `bennett(lr)` when self_reversing=true, ArgumentError on false with precise message, U03 probe rejects forged dirty-ancilla, end-to-end QROM lookup via `bennett_direct`.

**Test coverage:** the byte-identicality testset confirms `bennett_direct(lr) === bennett(lr)` semantically when `lr.self_reversing=true`. The U03 probe testset confirms `bennett_direct` doesn't bypass the validation harness — a forged self_reversing claim with a dirty-ancilla NOT-on-3 still raises. The end-to-end QROM testset is the canonical Sturm-shape example: 4-entry table, 2-bit index, W=4 output; circuit produces the right table entries AND uses forward-only gate count (length(c.gates) == length(lr.gates), NOT 2× + n_out).

**Gotchas / Lessons:**

1. **Post-7xng constructor arity shift.** The cvnb bead's description used the pre-7xng "7-arg backward-compat constructor" framing. After 7xng's dead-store removal earlier this session, that constructor is now the 6-arg form (no constant_wires), and the "9-arg form" with `self_reversing` is now the 8-arg form. Updated the docstring + README to match the post-7xng constructor counts. Lesson: when closing an ergonomics bead that cites specific constructor arities, re-check the source AFTER any preceding cleanup landed in the same session.

2. **Errors must cite the alternative.** `bennett_direct` raises `ArgumentError` if `self_reversing=false`. The error message names BOTH the constructor recipe AND `bennett(lr)` as the fallback path. CLAUDE.md §1 fail-loud is necessary but not sufficient — fail-loud-AND-actionable beats fail-loud-and-cryptic.

3. **Don't export `bennett_direct` if `bennett` itself isn't exported.** `bennett` is accessed via `using Bennett: bennett` (qualified import) — same pattern for `bennett_direct`. Adding it to the export list would create surface-area drift (pebbled_bennett, eager_bennett, etc. are exported, but the bare `bennett` is not — historical convention). Tests use the `using Bennett: bennett_direct` form to match.

**Rejected alternatives:**

- **Auto-promote a `self_reversing=false` lr to true after running the U03 probe** — proposed in the bead's "Acceptance criteria #1" Option A. Rejected: silently flipping a flag the caller chose is a footgun; the U03 probe is an EXPENSIVE validation pass (re-runs the gate sequence). If a caller wants auto-promote, they can call `_validate_self_reversing!(lr); bennett(<reconstructed lr with self_reversing=true>)` explicitly.
- **Extend `bennett(lr; assert_self_reversing=true)` kwarg instead of a new function** — kwarg-on-a-position-arg-API mixes paradigms. A separate function name communicates the contract more clearly at every call site.

**Filed (follow-ups):** none. Sturm.jl's ao1 / pw9 follow-up is downstream-side (their `qrom_lookup_xor!` switches to `bennett_direct`); not Bennett.jl's work to do.

**Test count:** 84,346 → **84,364** (+18, exact match).

---

## Session log — 2026-04-27 (post-bugs grind, LOC tier) — Bennett-7xng close (LoweringResult.constant_wires dead-store removal)

**Shipped:** see git log around the next commit; `LoweringResult.constant_wires::Set{Int}` field deleted from src/lower.jl, plus the `resolve!` kwarg, the `lower()` declaration, the `union!(constant_wires, wires)` line, and all 13 call sites passing `Set{Int}()` to `LoweringResult` across 8 test files + src/tabulate.jl. Stale docstring line in src/bennett_transform.jl removed.

**Why:** Bennett-7xng (P3 task; spun out as a drive-by from Bennett-5qrn / U57). The bead correctly identified that `resolve!` took `constant_wires::Set{Int}=Set{Int}()` as a kwarg with default empty Set, and NO caller threaded the lowering-scope set through. The mutation `union!(constant_wires, wires)` at lower.jl:249 was always operating on a caller-local empty Set that was discarded after the call. The field on `LoweringResult` was always materialised as the empty Set the lowering scope created at line 399. `_fold_constants` rebuilds its own `known` table from scratch; no consumer.

**Mode:** direct grind, "delete the dead store" disposition (Option B per the bead's prescription; (a) thread it through was rejected because no current consumer has an actual use for it).

**Net change:**
- `src/lower.jl`: -1 struct field, -1 line in `resolve!` signature, -3 lines in `resolve!` body (`union!` + comment), -1 line in `lower()` declaration, -1 line in main return call, -1 line in `_fold_constants` rebuild call. Backward-compat constructors trimmed from 7-arg/8-arg (with constant_wires) to 6-arg/7-arg shapes — same convenience surface, one fewer field per signature.
- `src/tabulate.jl`: dropped `Set{Int}(),` from the 9-arg constructor call.
- `src/bennett_transform.jl`: removed stale "Tracks constant_wires from the lowering result for future optimization" docstring line.
- 8 test files: dropped `Set{Int}()` from 13 LoweringResult constructor call sites.

**Test coverage:** no new test file added — the existing 84,346 assertions exhaustively exercise every reversible_compile path AND every constructor variant. Full Pkg.test green: `84346 pass + 2 pre-existing broken / 5m31s`. Test count unchanged (this is pure LOC reduction).

**Gotchas / Lessons:**

1. **Constructor-arg position is a backward-compat surface.** Every test file passing `Set{Int}()` as the 7th positional arg had to be updated. Found via `grep -rn "Set{Int}()" test/ src/` filtered to LoweringResult call sites. Deleting a struct field is mechanical but easy to miss a site — the smoke test (`reversible_compile + verify_reversibility + simulate`) caught only top-level breakage; the per-file test runs caught the test_self_reversing.jl + test_egu6 sites. Always re-grep AFTER editing the struct, not before.

2. **`docs/design/` snapshots are frozen but `src/` docstrings reference them.** The src/bennett_transform.jl docstring referenced `constant_wires` as "for future optimization" — this is the kind of forward-looking doc that rots when the field is removed but no commit touches the doc. Pattern: when removing a public-API field, grep its name in BOTH source AND docstrings AND the docs/ tree.

3. **Backward-compat constructors are convenience APIs, not contracts.** I considered preserving the 7-arg constructor for "external compatibility" but no Sturm.jl or other downstream consumer was found via grep. CLAUDE.md §11 ("don't add abstractions beyond what the task requires") + the bead's explicit "Option B is fine" makes the decision clean.

**Rejected alternatives:**

- **Option A (thread it through properly)** — would require ~30 LOC of plumbing through `lower_block_insts!` → `lower_binop!` → `resolve!` to actually populate the set, plus a downstream consumer (peephole, fold) to read it. The 5qrn peephole already operates without it; `_fold_constants` builds its own table. Adding plumbing for a hypothetical future use violates §11.
- **Keep the field but rename to `_constant_wires_unused` with a deprecation comment** — fossil noise. CLAUDE.md "avoid backwards-compat hacks like renaming unused _vars".

**Filed (follow-ups):** none.

**Test count:** 84,346 → **84,346** (unchanged — pure LOC reduction).

---

## Session log — 2026-04-27 (late evening) — Bennett-q04a / 59jj-cut close (_convert_instruction Union return — investigated, doc-only)

**Shipped:** see git log around the next commit; `_convert_instruction` (src/ir_extract.jl:1250-1271) gains a 17-line investigation comment + new contract test `test/test_q04a_convert_instruction_contract.jl` (9 assertions / 4 testsets) registered in runtests.jl.

**Why:** Bennett-q04a / 59jj-cut — review #18 F12 prescribed splitting `_convert_instruction` 17-arm Union return into `_single::IRInst` + `_expand!(out, ...)`. Filed 2026-04-26 as a 3+1 candidate.

**Mode:** investigation first per the chunk-045 directive. After empirical verification, "investigated, doc-only" disposition — same shape as today's heup + jc0y closes.

**Investigation finding — premise valid, cost/benefit out of proportion:**

1. **The 17-arm Union return IS real.** `code_warntype(_convert_instruction, ...)` shows `Body::Union{Nothing, IRAlloca, IRBinOp, IRBranch, IRCall, IRCast, IRExtractValue, IRICmp, IRInsertValue, IRLoad, IRPhi, IRPtrOffset, IRRet, IRSelect, IRStore, IRSwitch, IRVarGEP, Vector}` = 18 arms. Past Julia's union-splitting threshold (~4-7 arms).

2. **But extraction is one-shot per compile, NOT a hot path.** Empirical: extracting `(a::Int64, b::Int64) -> a + b * (a - b) + a*a - b*b` (7 instructions, optimize=false) costs 1.93 KiB / 1.93k allocations — dominated by LLVM module setup overhead (one-time-per-call), not the per-instruction Union return. The 18-arm Union contributes ≤16 B box per call × 7 = ~112 B = ~5% of the 1.93 KiB total.

3. **Refactor blast radius is significant.** The function body spans src/ir_extract.jl:1252-2200 (~950 lines) with 17+ return paths. Splitting into `_single::IRInst` + `_expand!(out::Vector{IRInst}, ...)` requires touching every return path PLUS the caller dispatch at src/ir_extract.jl:1003-1018. Per CLAUDE.md §2: any change to ir_extract.jl requires 3+1 protocol. Net cost (~2 hours of careful refactoring + 3+1 review cycle) vs ~5% extraction speedup on a one-shot path.

**Test coverage:** `test/test_q04a_convert_instruction_contract.jl` — 9 assertions / 4 testsets:

- **IRInst subtype count = 16** — pins the canonical set of concrete IR types. If a new subtype lands, the refactor calculus shifts (Union grows or shrinks). Trip = re-measurement signal.
- **Union arm bound 10-22** — `code_warntype` parsing validates the Body return type stays inside this band. Lower bound catches accidental Union explosion; upper bound catches accidental over-narrowing.
- **Caller dispatch shape** — pinned via canonical substring matches in src/ir_extract.jl: `ir_inst === nothing && continue`, `ir_inst isa Vector`, `ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch`. Any refactor must update all three together.
- **Extraction allocation linearity** — extraction cost on a 7-inst function < 200 KiB; ratio between 1-binop vs 5-binop function < 3×. Detects accidental N²-blowup if a future change moves expensive work into the per-instruction loop.

**Adjacent docstring update:** `_convert_instruction` (src/ir_extract.jl:1250-1271) gains a 17-line "Bennett-q04a / 59jj-cut" comment naming the Union arm count, the empirical cost breakdown, the proposed split prescription, the blast radius, and the contract test. Future agents resurrecting this work have the live numbers + the rejection rationale.

**Gotchas / Lessons:**

1. **Bead's prescription was structurally clean but cost/benefit out of proportion.** The split is mechanical and would type-stabilise the return — it's textbook good code. But the empirical perf gain (~5% on a one-shot extraction path) does not justify the 3+1 cycle + 950-line function body churn. Same calibration as jc0y earlier today: "real but modest, with high blast radius."

2. **`@code_warntype` Body line is the canonical type-stability check.** The contract test parses the warntype output as a string — fragile (Julia version drift could change the format), but no public API exists for "give me the inferred return type." Pinned with regex tolerant of both `Body::Union{...}` and `Body::IRInst` shapes so the test trips clearly when the situation changes.

3. **`InteractiveUtils.subtypes` (not `Base.subtypes`).** Same as jc0y; runtests.jl doesn't import InteractiveUtils, so the test file does its own `using InteractiveUtils: subtypes, code_warntype`.

**Rejected alternatives:**

- **Implement the split (`_single` + `_expand!`)** — would touch every return path of a 950-line function plus the caller dispatch. ~5% extraction speedup is not worth the 3+1 cycle. Defer until extraction becomes a measurable bottleneck (e.g. Sturm's million-line workloads).
- **Replace the Union with `IRInst` (abstract supertype) by wrapping `Vector` results in a sentinel `IRInstList <: IRInst`** — would require a new public type that is then immediately unwrapped at the call site. Adds API surface for no real benefit. Splitting is cleaner than wrapping.
- **Cache the dispatch result via `@nospecialize`** — would suppress Julia's specialisation on `inst::LLVM.Instruction` and likely INCREASE dispatch cost. Wrong direction.

**Filed (follow-ups):** none. The contract test is the regression guard. If Sturm or another downstream finds extraction OOMing on million-instruction workloads, resurrect q04a with the live numbers from the contract test as the bar to beat.

**Test count:** 84,337 → **84,346** (+9, exact match).

### Branch state at session-end

`main @ <next commit>`, pushed and up to date with `origin/main`. Worklog: chunk 047 has heup + jc0y + q04a; **all actionable Bennett.jl bugs are now closed.**

### Bd-tracked snapshot (post-q04a close)

```
bd ready -n 200 | grep '\[bug\]' → 2 open [bug] beads.
- P2: 25dm (blocked on z2dj IN-PROGRESS — T5-P6 dispatcher).
- P2: ponm (bd-infra: wisp_dependencies table missing — NOT a Bennett.jl bug).
- IN-PROGRESS: cc0.5 (P2 bug — Julia TLS allocator GEP base, T5-P6.3).
```

**Next agent — start here:** The bugs-only directive (chunk 045) is now exhausted on the actionable Bennett.jl side. Remaining work falls into three buckets:

1. **`25dm`** is gated on `z2dj` (T5-P6 dispatcher). Drive `z2dj` forward (3+1 per docs/design/p6_consensus.md) to unblock `25dm`'s @test_throws → real-pass conversion. This is non-bug work.
2. **`ponm`** is a beads-tool schema migration (`wisp_dependencies` missing). Cross-team / out-of-Bennett-jl scope.
3. **`cc0.5`** is in-progress (Julia TLS allocator GEP base). Already claimed; pickup if you have context.

If lifting the bugs-only directive: the chunk-045 refactor pile (P3 LOC reductions in lower.jl / ir_extract.jl, error monoculture, IROperand primitive obsession, etc.) is the next tier. Per chunk-045: "**~88.5% non-bugs** (refactors, docs, polish, structural, features)" — the non-bug catalogue is sizeable but lower priority than driving Sturm features.

---

## Session log — 2026-04-27 (late evening) — Bennett-jc0y / 59jj-cut close (gate-storage layout — investigated, doc-only)

**Shipped:** see git log around the next commit; `ReversibleCircuit` docstring (src/gates.jl:24-58) gains a "Storage layout decision" section + new contract test `test/test_jc0y_gate_storage_contract.jl` (11 assertions / 4 testsets) registered in runtests.jl.

**Why:** Bennett-jc0y / 59jj-cut — review #18 F13 claimed `Vector{ReversibleGate}` boxes ~56 MB on 1.4M-gate SHA-256 circuits AND `apply!` is type-unstable per gate in the simulate hot loop. Filed 2026-04-26 as a 3+1 candidate.

**Mode:** investigation first per the chunk-045 directive ("MEASURE before designing the fix"). After empirical verification, "investigated, doc-only" disposition (chunk 045 / 046 / 047 pattern, cf. 2yky / 3of2 / xiqt / y56a / yys3 / heup).

**Investigation finding — performance premise largely stale, memory premise modest:**

1. **`apply!` is NOT type-unstable in the simulate hot loop.** Empirical: `simulate(c, UInt64(7))` on a 28k-gate `x*x` circuit shows 4 allocations / 12.4 KiB total — bounded, not O(|gates|). Julia's union-splitting on the three concrete subtypes (`NOTGate` / `CNOTGate` / `ToffoliGate`) eliminates per-gate boxing inside the compiled `_simulate` function. The bead's claim was based on REPL-scope iteration (`for g in c.gates; apply!(b, g); end` at global scope), where dispatch IS dynamic — but that's not the production hot path.

2. **Memory savings are real but modest (~26%).** Live measurement on UInt64 `(a*b)+(c*d)*(a+b)` at 85k gates: boxed layout 3.7 MB vs flat 32-byte tagged union 2.7 MB. Linear extrapolation to a hypothetical 1.4M-gate SHA-256: 56 MB → 41 MB savings (~15 MB). Not a make-or-break reduction.

3. **Refactor blast radius is high.** 24+ source-file sites take `Vector{ReversibleGate}` as parameter type — every `lower_*!` helper (adder, qcla, multiplier, qrom, feistel, partial_products, parallel_adder_tree, fast_copy, shadow_memory), all strategy variants (eager, value_eager, pebbling, sat_pebbling, pebbled_groups), bennett_transform, simulator. Any storage-layout refactor must touch all of them AND must NOT shift the 39 pinned gate-count baselines.

The bead's three candidate fixes (tagged-union via SumTypes.jl; StructArrays.jl; three parallel concrete vectors) all have the same blast radius. Net cost vs benefit: not worth it today.

**Test coverage:** `test/test_jc0y_gate_storage_contract.jl` — 11 assertions / 4 testsets:

- **Allocation contract** — simulate on a 28k-gate UInt64 mul allocates < 200 KiB total AND < 8 B/gate. If apply! starts boxing per gate, both bounds trip immediately.
- **Memory layout contract** — pins `sizeof(NOTGate)=8`, `sizeof(CNOTGate)=16`, `sizeof(ToffoliGate)=24`. Live boxed-vs-flat ratio pinned at 20-40% (current ~26%); outside the band → baseline shifted.
- **Compiled-function loop shape** — `@noinline _drive!(bits, gates)` driving `for g in gates; apply!(bits, g); end` allocates < 1 KiB independent of `length(gates)`. Pins the canonical hot-loop shape so a future refactor can't accidentally lose union-splitting.
- **Method table** — exactly 3 concrete `ReversibleGate` subtypes; `subtypes(ReversibleGate) == {NOTGate, CNOTGate, ToffoliGate}`. If a 4th lands, the union-splitting analysis needs re-measurement.

**Adjacent docstring update:** `ReversibleCircuit` (src/gates.jl:24-58) gains a "Storage layout decision" section citing the empirical finding, the 26% memory delta, and the 24+ site blast radius. Future agents resurrecting this work have the live numbers to beat as a baseline.

**Gotchas / Lessons:**

1. **REPL-scope `for g in c.gates` ≠ in-function dispatch.** First measurement at global scope showed 111k allocs / 2.74 MiB on 28k gates → 4 allocs/gate, "confirming" the bead. Same loop wrapped in a `@noinline` function: < 1 KiB total. Julia union-splits inside a compiled function but not at REPL/global scope. Always measure with the same call shape the production hot path uses.

2. **Allocation-ratio assertions need an n_wires axis, not n_gates.** First test attempt asserted `a2/a1 < 0.10 * (n2_gates/n1_gates)` and tripped because `simulate`'s allocation footprint scales with `n_wires` (Bool buffer + input snapshot), not `n_gates`. Fixed by switching to a hard byte cap (200 KiB) plus a per-gate ratio (< 8 B/gate), both of which fail loud if per-gate boxing returns.

3. **`InteractiveUtils.subtypes` is NOT in `Base`.** Test file needed `using InteractiveUtils: subtypes`; runtests.jl doesn't import it transitively.

4. **The bead spec ("3+1 protocol per CLAUDE.md §2") was correct AT FILING TIME but the underlying premise stale.** Filing this as a 3+1 candidate was reasonable on the review's surface read; the empirical verification changed the calculus. CLAUDE.md §2's 3+1 trip-wire applies to behavior-changing changes; doc-only doesn't qualify.

**Rejected alternatives:**

- **Implement tagged-union via SumTypes.jl** — would touch 24+ lower_*! parameter signatures + every strategy variant + bennett_transform + simulator. Net memory savings ~15 MB on 1.4M-gate SHA-256; net dev cost: a 3+1 cycle plus careful per-baseline pin verification. Out of proportion. Defer until a real workload OOMs.
- **Implement hand-rolled flat union (Int64 tag + 3 wire indices, 32 B per element)** — same blast radius as SumTypes; smaller dependency surface; same defer rationale.
- **StructArrays.jl** — adds a dep, struct-of-arrays layout has worse cache behavior for the simulator's per-gate access pattern (which reads all wires of one gate at a time). Memory parity with the tagged union, no perf win.
- **Three parallel concrete vectors** — would require encoding gate ORDER (which currently is implicit in vector position). Adds a sequencing primitive; complexity dominates the win.

**Filed (follow-ups):** none. The contract test is the regression guard. Future work resurrecting this should start by re-running the test on a SHA-256 circuit and measuring the OOM threshold concretely.

**Test count:** 84,326 → **84,337** (+11, exact match).

---

## Session log — 2026-04-27 (evening) — Bennett-heup / U127 close (_fold_constants — investigated, doc-only)

**Shipped:** see git log around the next commit; expanded `_fold_constants` docstring (src/lower.jl:577-602) + new contract test `test/test_heup_fold_constants_contract.jl` (539 assertions / 4 testsets) registered in runtests.jl.

**Why:** Bennett-heup / U127 — review #12 torvalds B10 + #13 carmack F8 flagged "_fold_constants mixes three concerns; 93-line pass off-by-default" with no benchmarks and no tests.

**Mode:** direct grind, "investigated, doc-only" disposition (chunk 045 / 046 pattern, cf. 2yky / 3of2 / xiqt / y56a / yys3).

**Investigation finding — both load-bearing claims are stale:**

1. **"Off-by-default"** — already false. Bennett-epwy / U28 (commit a9dc115, 2026-04-24) flipped the default to `true` at `src/lower.jl:375` and at every `reversible_compile` entry point in `src/Bennett.jl` (lines 152, 230, 444). The flip-commit ships exhaustive correctness + the gate-count win documented in commit message. The chunk-045 calibration ("bead-claim numbers go stale") is in force here.

2. **"Mixes three concerns"** — empirically a single concern (constant propagation through reversible gates) with three operator-dispatch cases (NOTGate / CNOTGate / ToffoliGate). The function tracks ONE piece of state, `known::Dict{Int,Bool}`, and mutates it per gate. Splitting the dispatch would not separate concerns; it would duplicate the state-update logic three times. Per CLAUDE.md §12 (no duplicated lowering), keeping the single-pass shape is the right call.

3. **"No benchmark"** — also false. The U28 commit message documents `polynomial 872 → 562 (35% ↓)` and `x*x Toffoli 296 → 144`. Pre-existing tests `test/test_constant_fold.jl` + `test/test_epwy_fold_constants_default.jl` pin the default-true contract and the polynomial reduction.

**Live empirical baselines (post-5qrn peephole, measured 2026-04-27):**

| Function | off | on | Reduction |
|---|---:|---:|---|
| polynomial total | 848 | 482 | 43% |
| polynomial Toffoli | 352 | 168 | 52% |
| x*x total | 690 | 380 | 45% |
| x*x Toffoli | 296 | 144 | 51% |
| x*x depth | 97 | 89 | 8% |
| x*3 ratio | 343 | 106 | 3.24× |
| x+3 | 41 | 28 | 32% |

The 5qrn / U57 peephole pass (independent layer) further amplified the U28 wins since the bead was filed.

**Test coverage:** `test/test_heup_fold_constants_contract.jl` — 539 assertions / 4 testsets:

- **Default-true at every entry point** — `lower()` no-kwarg = explicit-on; `reversible_compile(f, Int8)` exhaustive correctness over Int8.
- **Per-gate-type dispatch witnesses** — hand-built `LoweringResult`s exercise each of 5 dispatch arms: NOTGate flip+materialize, CNOTGate constant-true control collapse, CNOTGate data-control pass-through, ToffoliGate one-known-false noop, ToffoliGate one-true+one-unknown CNOT reduction. Pins all dispatch arms reachable + behaving as documented.
- **Self_reversing short-circuit** — pointer-equality contract test (per Bennett-egu6 / U03): a self_reversing input returns `=== lr_sr` without any folding.
- **Empirical reduction baselines** — polynomial 482 ± 5%, Toffoli 168 ± 12, x*3 ratio ≥ 3×; exhaustive correctness over Int8.

**Adjacent docstring update:** `_fold_constants` docstring (src/lower.jl:577-602) now documents the dispatch arms, cites Bennett-heup / U127 + Bennett-epwy / U28 + Bennett-5qrn / U57, and pins the live baselines.

**Gotchas / Lessons:**

1. **Stale-bead disposition is the right pattern when the review was correct AT FILING TIME but the underlying defect has been independently fixed.** Bennett-heup was filed 2026-04-22; Bennett-epwy / U28 landed 2026-04-24 (2 days later). Without empirical verification I would have spent the session "splitting" a function whose flagship complaint had already been resolved. The chunk-045 directive's MEASURE-FIRST step (#3) catches this class of bead before any design work.

2. **Two reviewers describing the same surface in different language can both be stale.** Torvalds called it "second-pass peephole optimizer written by someone who felt like writing one"; Carmack called it "mixes three concerns, 93-line pass off-by-default". Both claims rest on the SAME premise (`fold_constants=false` default + no benchmarks) — and both are now equally stale post-U28.

3. **Hand-built `LoweringResult`s are the right tool for testing dispatch arms.** Each arm of `_fold_constants` has a specific pre-state in `known` that's easy to set up by choosing input_wires + initial gate sequence. Same pattern as Bennett-y986's hand-built `ParsedIR` for testing loop-internal dispatch (chunk 046).

4. **`gate_count(c).Toffoli` (capital T)** — the NamedTuple field is `Toffoli`, not `toffoli`. First measurement attempt errored on `getproperty`; field-name capitalization matters.

**Rejected alternatives:**

- **Split `_fold_constants` into 3 functions** (one per gate type) — would duplicate the `known::Dict{Int,Bool}` state-update logic three times AND require a new outer-loop driver. Net LOC increase, no clarity win, no behavior change. CLAUDE.md §12 (no duplicated lowering) prefers the single-pass shape.
- **Delete `_fold_constants` entirely** (torvalds B10 final option: "make it default, document the benefit, and test the counts — or delete it") — discarded; the empirical wins (43-52% reduction on representative workloads) are load-bearing for the gate-count regression baselines pinned in `test_gate_count_regression.jl`. Deletion would shift every pinned baseline.
- **Add `error("not implemented")` for unsupported gate types in dispatch** — the existing dispatch silently passes ToffoliGate-with-extractvalue / vector-typed gates through unchanged. CLAUDE.md §1 fail-loud would prefer an explicit error, but the pass operates on `ReversibleGate` which only has 3 concrete subtypes (NOTGate / CNOTGate / ToffoliGate). No fail-loud needed unless a 4th gate type is added.

**Filed (follow-ups):** none. Per the bugs-only directive, no follow-up beads.

**Test count:** 83,787 → **84,326** (+539, exact match).

**Bd-tracked snapshot (post-heup close):**

```
bd ready -n 200 | grep '\[bug\]' → 4 open [bug] beads (down from 5).
- P2: 25dm (blocked on z2dj IN-PROGRESS), ponm (bd-infra not Bennett.jl).
- P3: q04a, jc0y (both 3+1 refactors, yesterday's filings).
- IN-PROGRESS: cc0.5 (P2 bug — Julia TLS allocator GEP base, T5-P6.3).
```

**Next agent — start here:** Continue bugs-only. Of the 3 remaining actionable beads (excluding 25dm blocked + ponm bd-infra + cc0.5 in-progress), only `q04a` and `jc0y` remain — both 3+1 refactors of yesterday's `59jj` cuts:

- **`q04a`** — split `_convert_instruction` 17-arm Union return into `_single` + `_expand!`. Touches `src/ir_extract.jl`. Per CLAUDE.md §2: 3+1 protocol required.
- **`jc0y`** — `ReversibleCircuit.gates` storage layout (abstract `Vector{ReversibleGate}` boxes pointers, ~56 MB on 1.4M gates). Touches `src/gates.jl`. Per CLAUDE.md §2: 3+1 protocol required.

Both have measurable empirical baselines (memory pressure, allocation counts). Pickup order: `jc0y` first (smaller blast radius — the storage layout is one struct field; the change is contained), then `q04a` (touches the extractor's hot dispatch path; needs careful baseline measurement).

After both 3+1s land, the [bug] backlog is exhausted (excluding bd-infra `ponm` and cross-team-blocked `25dm`).

### Branch state at session-end

`main @ <next commit>`, pushed and up to date with `origin/main`. Worklog: chunk 047 starts here (chunk 046 hit 508 lines after the yys3 entry, well past the ~280 cap).

---
