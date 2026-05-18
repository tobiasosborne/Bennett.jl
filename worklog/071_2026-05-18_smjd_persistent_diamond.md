## Session log — 2026-05-18 — Bennett-25dm T5 corpus triage post-z2dj+smjd (negative result)

**Shipped:** Triage-only — refreshed stale "Current error" comments in `test/test_t5_corpus_julia.jl` (TJ1, TJ2, TJ4), `test/test_t5_corpus_rust.jl` (TR1, TR2, TR3), and `test/test_t5_corpus_c.jl` (header + TC1/TC2/TC3) to reflect actual 2026-05-18 failure modes. NO `@test_throws` flips — every fixture except TJ3 is still RED. TJ3 was already flipped to GREEN by Bennett-cc0.4 back on 2026-04-21 and is unchanged here.

**Triage table:**

| Fixture | Old expected error                                       | Today's behaviour                                                       | Class | Action                          |
|---------|----------------------------------------------------------|-------------------------------------------------------------------------|-------|---------------------------------|
| TJ1     | `Unknown value kind LLVMGlobalAliasValueKind`            | `llvm.memset.p0.i64: volatile memset is not supported` (Bennett-9nwt P3) | C     | Refresh comment; no flip        |
| TJ2     | `Unknown value kind LLVMGlobalAliasValueKind`            | Same volatile-memset error                                              | C     | Refresh comment; no flip        |
| TJ3     | (Was already flipped GREEN by cc0.4 2026-04-21)          | GREEN, 118 gates, 256/256 oracle, verify_reversibility=true              | A→Done | None (already flipped)         |
| TJ4     | `lower_var_gep!: GEP base thread_ptr not found`          | Same volatile-memset error                                              | C     | Refresh comment; no flip        |
| TC1-3   | `UndefVarError: extract_parsed_ir_from_ll`               | Skipped locally (no clang). In-code expectation: extract-time `malloc` callee error (post-5oyt) | D (carried) | Refresh comment only          |
| TR1     | `UndefVarError: extract_parsed_ir_from_ll`               | `LLVM.LLVMException: expected type` on `getelementptr inbounds nuw`     | D     | Refresh comment; no flip        |
| TR2     | Same                                                     | `LLVM.LLVMException: expected type` on `trunc nuw i8 %1 to i1`          | D     | Refresh comment; no flip        |
| TR3     | Same                                                     | `LLVM.LLVMException: expected type` on `trunc nuw i64 %_5 to i1`        | D     | Refresh comment; no flip        |

**Why:** Bennett-25dm was the umbrella triage bead for "T5 corpus is still @test_throws". With z2dj closed 2026-05-16 (persistent dispatcher arm + `mem=:persistent` kwarg) and smjd closed 2026-05-18 (non-entry-block persistent stores via output-MUX), the moment to find out what actually compiles. Result: ZERO new fixtures green. Both blockers moved deeper but neither is on the z2dj/smjd path.

**Gotchas / Lessons:**

1. **The TJ1/TJ2/TJ4 blocker moved — Bennett-9nwt Phase 2 (2026-05-03) is now the first wall, not the documented extract-side bugs.** Julia emits a volatile (`i1 true`) `llvm.memset.p0.i64(ptr %gcframe1, i8 0, i64 N, i1 true)` to zero-init the GC frame at function entry. 9nwt Phase 2 added predicate 3 (`vol_v == 0`) BEFORE the silent-drop fast path (predicate 8) that historically swallowed GC-frame zeroing. Now every Julia function with GC-managed locals (every Vector/Dict/Array{T}(undef) function) hits this wall before any downstream lowering runs. The original TJ1/TJ2 root cause (LLVMGlobalAliasValueKind) and TJ4 root cause (thread_ptr GEP, Bennett-cc0.5) still exist — they're just unreachable now. The `@test_throws ErrorException` contract is intact because both old and new errors are `ErrorException`, but the precise message differs. **Take-home:** when 9nwt-style "tighten the guard" beads land, audit upstream-of-9nwt tests for stale "current error" comments. Filed Bennett-8su4 to track the volatile-memset → fresh-alloca whitelist.

2. **Julia frontend SROA on NTuple was already documented (worklog/071 gotcha 1).** The smjd test rewrite couldn't use Julia source for diamond-CFG persistent tests because SROA decomposes `NTuple{9,UInt64}` state into scalar SSAs before any LLVM `alloca` materialises. Same root cause means we can't use Julia source for TJ1/TJ2 either — even if 8su4 lands, the Vector backing `NTuple` would also be SROA'd. The only viable test pattern for end-to-end T5 corpus coverage of Julia-source code is hand-built `.ll` fixtures (mirroring `test_t5_p6_persistent_dispatch.jl`). The `test_t5_corpus_julia.jl` Vector/Dict/Array{T}(undef) patterns are fundamentally NOT representative of what `reversible_compile(julia_func, types)` actually compiles in 2026-05. **Take-home:** when 8su4 lands, expect TJ1/TJ2 to expose SROA as the next blocker; do NOT pre-emptively flip them.

3. **Rust corpus is blocked by upstream LLVM-version skew, not by any z2dj/smjd work.** `build/t5_tr*.ll` was generated with rustc 1.95.0 which emits LLVM 19+ syntax (`inbounds nuw` on GEP, `trunc nuw ... to i1`). Local toolchain is LLVM 18 via LLVM.jl. Parse fails BEFORE extraction. Same skew already encountered in Bennett-land worklog/070 gotcha 6. Filed Bennett-n88f. Until resolved, TR1/TR2/TR3 cannot exercise T5-P6 dispatcher coverage. Current `@test_throws Union{ErrorException, LLVM.LLVMException}` contract still holds (LLVM.LLVMException covers the parse failure), so the tests don't break, they just don't test what was intended.

4. **C corpus skips silently locally (no clang on PATH).** `test_t5_corpus_c.jl` has a `have_clang` guard that `@test_skip`s when clang isn't found. CI mode (`BENNETT_CI=1`) would promote this to hard error per Bennett-srsy / U103. Triage couldn't probe TC1/TC2/TC3 directly; the in-code expectations from post-Bennett-5oyt (loud-error on unregistered `malloc` callee at extract) are carried forward unchanged.

5. **`bd create` + dolt-push HTTPS auth failure is recurrent.** Both new beads (8su4, n88f) succeeded at local-create but failed at dolt-push with `fatal: could not read Username for 'https://github.com'`. Same gotcha worklog/070 §3 documented. Local `bd list` confirms both beads materialised; the dolt-cache sync is the only thing affected. Same workaround: continue, rely on the periodic dolt-cache bundled-with-source-commit pattern (CLAUDE.md "Dolt-cache commit hygiene") to push the new beads in this session's commit.

**bd close decision:** Bennett-25dm **STAYS OPEN**. Per the triage rubric, "all 10 fixtures still RED" maps to "don't close". TJ3 was flipped before 25dm even existed as a triage exercise; everything else is RED, and the new blockers (Bennett-8su4 for TJ1/TJ2/TJ4, Bennett-n88f for TR1/TR2/TR3) are NOT downstream of z2dj/smjd. Recommended reframe for the next agent: 25dm's title/description should note that z2dj + smjd are done but the remaining 9 fixtures are blocked on (a) 8su4 (volatile-memset, in turn blocked by SROA), (b) cc0.5 (thread_ptr), (c) cc0.x (LLVMGlobalAlias), (d) n88f (LLVM-version skew for Rust).

**Files changed:**
- `test/test_t5_corpus_julia.jl` (~+30, -25): header + TJ1, TJ2, TJ4 "Current error" comments refreshed; testset bodies unchanged.
- `test/test_t5_corpus_c.jl` (~+15, -15): header + TC1, TC2, TC3 "Current error" comments refreshed (carried from in-code post-5oyt expectations; could not re-probe locally).
- `test/test_t5_corpus_rust.jl` (~+30, -25): TR1, TR2, TR3 "Current error" comments refreshed to LLVM-version-skew root cause.
- (No source changes, no new fixtures, no test flips.)

**Verification:**

| File | Result |
|---|---|
| `test/test_t5_corpus_julia.jl` (post-edit) | 260/260 pass (2 + 258 across two testsets) |
| `test/test_t5_corpus_rust.jl` (post-edit) | 6/6 pass |
| `test/test_t5_corpus_c.jl` (post-edit) | 1/1 broken-test placeholder (no clang locally; expected) |

**Follow-up beads filed:**
- **Bennett-8su4** (P2, OPEN) — 9nwt-volatile: Julia GC-frame volatile memset blocks TJ1/TJ2/TJ4. Acceptance: those fixtures progress past the volatile-memset error. Three suggested fix options in the bead body (whitelist-on-fresh, reorder predicates, gcframe alloca tag).
- **Bennett-n88f** (P3, OPEN) — t5-rust-llvm-skew: rustc>=1.95 emits LLVM 19+ syntax that local LLVM 18 cannot parse. Acceptance: TR1/TR2/TR3 can be extracted. Four suggested fix options.

**Next agent starts here:** pick one of (a) **Bennett-8su4** (the natural 25dm continuation — would unblock TJ4 partially, TJ1/TJ2 still need the SROA workaround per gotcha 2 above); (b) **Bennett-cc0.5** (thread_ptr GEP — already in-progress per `bd show`; orthogonal to this triage); (c) **Bennett-n88f** (low-touch — regenerate Rust `.ll` fixtures with an older rustc, no source changes); (d) **Bennett-6883** (`:okasaki`/`:hamt`/`:cf` persistent_impl arms — extends the working z2dj dispatcher to more impls); (e) pivot to non-T5 — **Bennett-tzrs** (`_convert_instruction` god-function split), **Bennett-vdlg** (`lower.jl` split).

---

## Session log — 2026-05-18 — Bennett-smjd non-entry-block persistent stores via block-pred-guarded MUX (3+1 — implementer)

**Shipped:** `src/lowering/memory.jl` gains `_lower_store_via_persistent_guarded!` (Plan Option A: output-MUX) plus a tiny refactor: the entry-block fast path was factored out of `_lower_store_via_persistent!` into a new `_emit_persistent_set_unconditional!` helper so the top-level dispatcher just splits on block_label. Non-entry-block persistent stores now lower as: (a) capture pre_state via `copy(ctx.vw[alloca_dest])`; (b) emit unconditional `IRCall` to `impl.pmap_set` into a fresh `__persistent_state_guarded_<alloca>_<n>` SSA, producing post_state wires; (c) `lower_mux!(ctx.gates, ctx.wa, [pred_wire], post_state, pre_state, state_w)` yields `merged`; (d) rebind `ctx.vw[alloca_dest] = merged`. Bennett's reverse pass is unchanged — it uncomputes the IRCall AND the MUX self-inversely; all ancillae return to zero. No new IR opcodes, no new callees, no new BennettStrategy. Test file `test/test_t5_p6_persistent_dispatch.jl` rewritten: testsets 1 + 3 now use hand-built `.ll` fixtures parsed via `LLVM.Context() + parse(LLVM.Module, …) + Bennett._module_to_parsed_ir` (mirroring `test_memory_corpus.jl::_compile_ir`); testsets 2, 4, 5, 6 unchanged. Testset 3 flipped from RED (`@test_throws` on the smjd refusal) to a positive correctness test with 4 corner cases + 8-trial random sweep + gate-count comparison vs an equivalent shadow-memory diamond baseline (`alloca i8, i32 256`).

**Why:** Bennett-z2dj closed 2026-05-16 with the consensus §3 R1 "non-entry block refused" guard at `_lower_store_via_persistent!` (memory.jl:312-319, pre-edit). That guard was correct as a stopgap but blocked the common case of "persistent store guarded by an `if`" — exactly the canonical Sturm.jl use case where a quantum-controlled function does conditional mutation. Bennett-smjd is the natural follow-up and overlaps Bennett-8liz (filed earlier same day). Per CLAUDE.md §2 this is a core change (`src/lowering/memory.jl`), so the 3+1 protocol applied: 2 Plan-Opus proposers + this implementer + orchestrator reviewer. Output-MUX (Option A) was synthesised from the two proposers' independent designs as the cheapest correct lowering.

**Gotchas / Lessons:**

1. **Julia frontend SROA on NTuple state — NOT callee-inlining — was the real reason the prior z2dj testsets 1+3 were RED.** Worklog/070 gotcha 1 (z2dj close-out) blamed callee-inlining for `_z2dj_diamond_persistent` never reaching the persistent dispatcher under `reversible_compile`. Proposer B's diagnosis corrected this: the actual cause is Julia's frontend SROA pass, which decomposes the NTuple{9,UInt64} state into scalar SSAs before any LLVM alloca ever materialises. `@noinline` on the helper doesn't help — SROA still fires inside the helper body. The only path to a faithful test is to hand-build the `.ll` fixture and parse it via `LLVM.Context` + `parse(LLVM.Module, …)` + `Bennett._module_to_parsed_ir`. **Take-home:** when a "callee-inlining bypasses our dispatcher" hypothesis surfaces for persistent-mutation tests, suspect SROA-on-NTuple first; verify by inspecting `code_llvm(…; optimize=false)` for an actual `alloca` instruction. None of the Julia-source diamond patterns I tried (Vector, Ref{NTuple}, Ref{NTuple{...}}, …) reliably produced a dynamic-n alloca that survived to lowering. The `.ll`-fixture pattern is the only robust approach.

2. **`@gname` LLVM function names must start with `julia_` or `j_`.** First cut of the fixtures named the functions `@smjd_entry_block` and `@smjd_diamond_persistent`. `_module_to_parsed_ir` hard-errors with `ir_extract.jl: no julia_* function found in LLVM module` — `_find_entry_function` (src/extract/module_walk.jl:15) filters on the `julia_` / `j_` prefix to skip declarations and the LLVM runtime stubs. Renamed all three fixtures to `@julia_smjd_*` and they parsed cleanly. **Take-home:** any hand-written `.ll` fixture must use a `julia_<name>` function name; existing fixtures under `test/fixtures/ll/` already follow this convention but it's not documented anywhere except in the error message.

3. **`lower_mux!` takes `cond::Vector{Int}` not `cond::Int`.** Per the call signature at `src/lowering/arith.jl:522`: `lower_mux!(g, wa, cond, tv, fv, W)` and the body uses `cond[1]` in the `ToffoliGate`. Every existing call site wraps a single predicate wire as `[pred_wire]` (see `arith.jl:519`, `phi.jl:159`, `aggregate.jl:382`, `cfg.jl:350`). The orchestrator plan flagged this: "If it takes `cond_wires::Vector{Int}`, wrap pred_wire as [pred_wire]." Verified and done. **Take-home:** Bennett's MUX is always 1-bit cond per call; the `Vector{Int}` typing is to share the IROperand resolution shape with the binop / select sites, not because multi-bit MUX is meaningful.

4. **Gate-count ratio is actually 0.09×, not the 4× ceiling.** Diamond-CFG persistent total=3718 gates vs shadow total=40502 gates. The persistent dispatcher's IRCall to `linear_scan_pmap_set` produces a fixed 4-slot branchless write (linear scan max_n=4); shadow-memory's `:shadow_checkpoint` strategy at `alloca i8, i32 256` fans out over all 256 slots. For small persistent maps this is a huge win; the comparison would invert if the persistent impl scaled by n (it doesn't here). Left the test's 4× ceiling untouched as a defensive bound — it's loose enough that future impl changes won't tip it without an obvious regression signal. **Take-home:** the cross-strategy gate-count comparison is asymmetric — persistent wins at the small end because its cost is fixed at max_n=4, shadow wins at the large-mutation-density end because its cost scales by mutation count not alloca size. BENCHMARKS.md doesn't track this kind of comparison yet; filing as a follow-up (see below).

5. **No new callees needed, no `_CALLEE_GROUPS` drift, no kmuj fixup.** Output-MUX (Option A) reuses the existing `linear_scan_pmap_set` callee that z2dj Step 7 already registered. The MUX itself is emitted via direct gate construction (`lower_mux!`), no callee involved. Verified: `test_kmuj_callee_groups.jl` 327/327 unchanged. The Option B (input-guarded set) variant the spec rejected WOULD have needed a new `linear_scan_pmap_set_guarded` callee — that callee count change would have tripped kmuj. Choosing Option A side-stepped that.

6. **Entry-block-fast-path factoring kept the byte-identical contract.** The body that used to be the second half of `_lower_store_via_persistent!` (after the refusal block) became `_emit_persistent_set_unconditional!` verbatim. Entry-block stores still emit exactly one `IRCall` + a `ctx.vw[alloca_dest]` rebind to the post-call wires. Verified: `test_persistent_interface.jl` gate-count anchor `total=404, Toffoli=90` unchanged. **Take-home:** for refactor-and-extend patterns where the existing path must stay byte-identical, factor first (with zero behaviour change), then add the dispatch and the new path. The factoring commit (mental commit, not literal) can be re-verified against the original gate count.

**Rejected alternatives:**

- **Option B (input-guarded set: fold `pred_wire` into slab inputs before the call).** Rejected per the orchestrator plan + the `linear_scan_pmap_set` impl shape. `pmap_set` is branchless and writes to ALL slots (each via `ifelse` on slot index); there's no clean way to "skip" the write without corrupting the map invariant when `pred=0` (e.g. the `count` field would get mutated regardless). Option A's output-MUX cleanly preserves the pre-state when `pred=0`.
- **Option C (controlled-IRCall: lift the entire pmap_set call to a `ControlledCircuit` keyed on `pred_wire`).** Rejected per the plan. Would inflate every gate inside `pmap_set` to a guarded variant — much larger than a single MUX at the call boundary. The output-MUX cost is `state_w · (3 CNOT + 1 Toffoli) = 576 · 4 = 2304` extra gates per guarded store; the controlled-call variant would add ~1 Toffoli per gate in `pmap_set` (~thousands of gates).
- **Test-rewrite alternative (a): `@noinline` + registered-callee wrapper for `_z2dj_diamond_persistent`.** Rejected per gotcha 1: SROA on NTuple is the actual root cause, not callee-inlining. `@noinline` would have left the bypass intact.
- **Test-rewrite alternative: shadow-fixture using `alloca i8, i32 4` (small N to match persistent's max_n=4).** Would have produced a more apples-to-apples gate-count comparison, but would also have dispatched to a `:mux_exch_4x8` strategy rather than `:shadow_checkpoint`, changing the comparison axis. Picked `alloca i8, i32 256` → `:shadow_checkpoint` because it matches the SAME dispatch class as the persistent path (both are dynamic-idx, both are "universal" fallback strategies for their respective alloca shapes). 4× ceiling is loose enough to absorb either choice.

**Verification:**

| File | Result |
|---|---|
| `test/test_t5_p6_persistent_dispatch.jl` | **323/323 pass** (was 290/2 fail under z2dj; +33 new asserts in the rewritten testset 3) |
| `test/test_persistent_interface.jl` | **88/88 pass** (gate-count anchor: total=404, Toffoli=90 — UNCHANGED) |
| `test/test_gate_count_regression.jl` | **39/39 pass** (BENCHMARKS.md baselines hold) |
| `test/test_kmuj_callee_groups.jl` | **327/327 pass** (no callee added) |
| `test/test_increment.jl` | **257/257 pass** |
| `test/test_universal_dispatch.jl` | **293/293 pass** |
| `test/test_memory_corpus.jl` | **582/582 pass** (peer sweep: shadow / MUX-EXCH paths unaffected) |
| `test/test_self_reversing.jl` | **12/12 pass across 4 testsets** (no self-reversing tag mutation) |

Diamond-CFG gate counts (raw measurement, not pinned):
- Persistent (`alloca i64, i32 %n` → 576-wire slab, output-MUX guarded store, `linear_scan_pmap_get` load): **3718 gates / 14835 wires**
- Shadow (`alloca i8, i32 256` → 2048-bit array, `:shadow_checkpoint` for both store and load): **40502 gates / 18247 wires**
- Ratio: persistent ≈ 0.09× shadow (much better than the 4× ceiling).

**Files changed:**
- `src/lowering/memory.jl` (+~115, -25): new `_lower_store_via_persistent_guarded!` (Option A: output-MUX) and `_emit_persistent_set_unconditional!` (refactored entry-block fast path); `_lower_store_via_persistent!` becomes a 12-line dispatcher splitting on `block_label == ctx.entry_label`. Docstrings updated.
- `test/test_t5_p6_persistent_dispatch.jl` (~+200, -30): testsets 1 + 3 rewritten to use hand-built `.ll` fixtures via the `_compile_ir_persistent` helper; 3 new `const _SMJD_FIXTURE_*` strings for entry-block / diamond-persistent / diamond-shadow IR; 2 new oracles. Testsets 2, 4, 5, 6 unchanged.

**Follow-up beads filed:**
- (Closed) `Bennett-8liz` — closed-as-superseded by Bennett-smjd. Bennett-8liz proposed a `linear_scan_pmap_set_guarded` callee (Option B / input-guarded variant); smjd's Option A (output-MUX) achieves the same correctness without a new callee.
- No new beads filed. Potential future work observed but not filed today:
  - Loop-body persistent stores (the smjd refactor handles diamond CFG but loop-body stores need `lower_loop!`-level integration to thread the iteration predicate; today they'd hit the same dispatcher and emit one MUX per iteration, which works but is wasteful).
  - Multi-origin × non-entry intersection (currently refused with a clear AssertionError in `_lower_store_via_persistent_guarded!`; the message points at consensus §R4 as the open question).
  - BENCHMARKS.md cross-strategy ratio table for diamond-CFG memory (gotcha 4) — not yet a canonical baseline.

**Next agent starts here:** pick one of (a) **Bennett-6883** (other `persistent_impl` arms — `:okasaki` / `:hamt` / `:cf`); (b) advance to T5-P7a (`Bennett-ktt8` head-to-head Pareto benchmark for persistent vs shadow at diamond/loop-body memory patterns — the smjd diamond fixture gives a good starting harness); (c) pivot to non-T5 in-progress beads: **Bennett-cc0.5** (thread_ptr GEP base — TLS allocator bug) or **Bennett-tzrs** (`_convert_instruction` 649-line god-function split — needs 3+1).

---
