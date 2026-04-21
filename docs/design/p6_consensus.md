# T5-P6 Consensus — `:persistent_tree` dispatcher arm

**Bead**: Bennett-z2dj. Labels: `3plus1,core`.
**Date**: 2026-04-21.
**Inputs**: `docs/design/p6_proposer_A.md` (1310 lines), `docs/design/p6_proposer_B.md` (1425 lines).
**Orchestrator**: this agent, reviewing both independently.
**Protocol**: CLAUDE.md §2 (3+1).

---

## 1. Chosen design — B-primary, A-supplemental

B wins on almost every structural decision because it minimises blast
radius. A's detailed risk analysis and `validate_persistent_config`
structure are carried forward.

### Structural decisions (B)

| Question | Choice | Rationale |
|---|---|---|
| Dispatcher signature | **Unchanged.** New sibling `_pick_alloca_strategy_dynamic_n(ctx, inst)` called only from `lower_alloca!`. | Every existing `_pick_alloca_strategy` test (test_universal_dispatch.jl:90–115) stays a pure equality assertion. A's `DYNAMIC_N = -1` sentinel would pollute shape tuples and surprise future readers. |
| Persistent-state bookkeeping | **Parallel `persistent_info::Dict{Symbol, PersistentMapImpl}` on LoweringCtx.** Do NOT extend `alloca_info`. | Readers of `alloca_info` (≥10 call sites across lower.jl) need zero changes. Strictly additive. |
| LoweringCtx additions | **Three symbol fields** (`mem`, `persistent_impl`, `hashcons`) + the new dict. No `PersistentConfig` struct. | A's struct is fine but introduces a type for 3 symbols. Flat fields match the existing `add/mul/strategy` kwarg pattern. |
| Default `mem=` | **`:auto`** (not `:classical`). | Matches existing `add=:auto`, `mul=:auto`, `strategy=:auto` convention. Leaves room for M5.7 (P7a) to flip `:auto` to pick `:persistent` automatically for dynamic-n without an API break. |
| Semantics of `mem=:persistent` | **Permission, not forcing.** Const-n allocas still go through shadow / MUX / shadow_checkpoint. Only dynamic-n routes through the new arm. | Guarantees BENCHMARKS.md byte-identical even when users explicitly opt in. B's §3.3 table codifies this; consensus pins it via a dedicated regression test. |
| `pmap_new` initial-state emit | **Skip for linear_scan.** WireAllocator zero invariant gives all-zero state for free (matches `linear_scan_pmap_new`'s return). Non-zero-init impls (e.g. Okasaki with sentinel root) would need an explicit IRCall — but they're **out of MVP scope**. | Cheaper gate count; simpler MVP. The cost is documented as an impl-specific constraint. |
| State-bundle width | **Call `impl.pmap_new()` at Julia compile time and inspect NTuple length.** | B's approach. Concrete, not inference-dependent. A's `Base.return_types` is fragile. |
| Non-entry-block persistent stores | **Hard-error in MVP.** Diamond-CFG RED test uses `@test_throws`. | Matches M3a precedent for scope-limiting. Follow-up bead for block-pred-guarded persistent stores. |
| Multi-origin × persistent | **Hard-error.** Single-origin only in MVP. | Follow-up bead. |
| Impls in MVP | **Linear_scan only.** `:okasaki` / `:hamt` / `:cf` and `hashcons=:naive|:feistel` return crisp NYI errors. | Matches the sweep finding (linear_scan is the default). Follow-up bead(s) wire the other arms. |
| GEP / PtrOffset | **Early-return for persistent base.** `lower_ptr_offset!` and `lower_var_gep!` detect `haskey(ctx.persistent_info, base)` and skip the flat-wire-slab logic. Static-offset GEP requires `offset_bytes == 0` in MVP. Dynamic-idx GEP propagates `inst.index` as the pmap key. | B's §5.5. |

### Carried forward from A

1. **`validate_persistent_config` at `reversible_compile` entry** — A §R3. Checks that selected impl's callees are registered via `is_registered_callee`. Crisp error surface at the kwarg call site, not buried mid-lowering.
2. **A's R5 (hashcons regression) discipline** — `hashcons=:none` is a strict no-op by construction in this PRD; no code path hashconses. Guards against M5.4 silently touching the :none path.

### Dropped from both

- A's `DYNAMIC_N = -1` sentinel. Rejected — see above.
- B's §14 rename suggestion `:persistent_map` (vs bead's `:persistent_tree`). **Keep `:persistent_tree`** to match the bead title and the PRD. Cosmetic rename is follow-up.

---

## 2. Research step — RESOLVED 2026-04-21, pivoted to 3-bead decomposition

The load-bearing question B §12 flagged ("does `lower_call!` correctly
handle an NTuple aggregate input arg?") was answered by running the
procedure. **Result: no — `extract_parsed_ir` itself errors on the
callee under both optimize=true and optimize=false.** Full research in
`docs/design/p6_research_local.md` (1646 lines) and
`docs/design/p6_research_online.md` (1157 lines).

**The failure is three distinct bugs, not one:**

| Bug | Location | Symptom | New bead |
|---|---|---|---|
| α | `src/lower.jl:1869` hardcodes `Tuple{UInt64, ...}` for callee arg extraction | Any non-UInt64 callee signature → MethodError in `extract_parsed_ir(callee, arg_types)` | **Bennett-atf4** |
| β | `src/ir_extract.jl:517-520` rejects vector-valued sret stores | `optimize=true` NTuple returns hit `store <4 x i64>` from SROA+SLPVectorizer | **Bennett-0c8o** |
| γ | `src/ir_extract.jl:451-461` rejects `llvm.memcpy` sret writes | `optimize=false` NTuple returns emit memcpy-from-alloca pattern | **Bennett-uyf9** |

External precedent anchored:
- Julia frontend emits `NTuple{N,T}` as LLVM `ArrayType [N x T]`, not vector (Julia `src/cgutils.cpp:1023-1048`, `jl_special_vector_alignment` gated on VecElement only).
- On x86_64 SYSV, 72 bytes > 16-byte ABI threshold → always sret.
- Form B arises because Julia's pipeline runs SROA (4×) + SLPVectorizer + VectorCombine at `-O2` (`src/pipeline.cpp:362-553`). SROA's "vector promotion" feature is the specific mechanism.
- **Enzyme.jl solved this exact problem** (MIT-licensed) via `memcpy_sret_split!` + `copy_struct_into!` in `post_optimize!`. This is the battle-tested precedent for Form A.
- LLVM stock `Scalarizer<load-store>` pass (`llvm/lib/Transforms/Scalar/Scalarizer.cpp`, ScalarizeLoadStore=true) mechanically splits `store <N x iW>` into N scalar stores — the stock solution for Form B.
- Bennett's existing `_resolve_vec_lanes` helper (`ir_extract.jl:1863-1907`) already implements vector-lane decomposition — ~90% of Form B machinery is in place.

**Updated plan:** T5-P6 (Bennett-z2dj) is **blocked on Bennett-atf4 + Bennett-0c8o + Bennett-uyf9**. Each is its own 3+1 core change with its own RED→GREEN cycle. When all three land, this consensus doc's §3-8 implementation stands unchanged. The consensus design was correct — it just assumed infrastructure that doesn't yet exist.

---

## 3. Ancilla hygiene + false-path correctness

Per CLAUDE.md "Phi Resolution and Control Flow — CORRECTNESS RISK" and
PRD §11 R1:

- **Non-entry-block persistent stores**: refused at `lower_alloca!`-
  time so Bennett's reverse pass never sees an unguarded persistent
  store. Diamond-CFG RED test asserts `@test_throws`.
- **Ancilla return to zero**: linear_scan_pmap_set is pure + branchless;
  Bennett's post-copy reverse pass uncomputes every gate. The pmap_new
  output is all-zero (no NOT gates emitted), so the reverse pass
  un-computes to all-zero naturally. Acceptance test's
  `verify_reversibility(c)` catches any leak.

---

## 4. RED test file — consensus

File: `test/test_t5_p6_persistent_dispatch.jl`. Structure follows B's
§8 with one correction: the roundtrip test must respect linear_scan's
`max_n = 4` — no more than 4 distinct keys per trial.

Six testsets:

1. **Dispatcher-level `mem=:auto` hard-error** — dynamic n_elems under
   `:auto` errors with a message naming `mem=:persistent`.
2. **3-key roundtrip under `:linear_scan`** — hand-crafted IR with
   dynamic-idx GEPs for stores + lookup. Reference via
   `Bennett.pmap_demo_oracle` (already exists in `src/persistent/harness.jl`).
   Concrete corner cases (zeros, hit, miss) + a small random sweep.
3. **Diamond CFG — persistent store in non-entry block** —
   `@test_throws Exception`.
4. **Regression: existing `_pick_alloca_strategy` arms** — verbatim
   from test_universal_dispatch.jl:90–115, asserts byte-identical
   returns.
5. **`mem=:persistent` + const-n is a no-op** — same const-n IR as
   existing tests, pass `mem=:persistent`, assert gate count stays in
   the MUX-EXCH regime (< 10,000), `verify_reversibility` passes.
6. **NYI kwargs fail loud** — `persistent_impl=:okasaki` and
   `hashcons=:naive` both `@test_throws`.

Implementer copies B §8's full text and adjusts the `max_n = 4`
overflow corner case if needed.

---

## 5. Implementation sequence (consensus)

13 ordered steps. Each has a concrete feedback check. Start with the
research step, then RED-first per CLAUDE.md §3.

### Step 0 — Research (BEFORE ANY CODE)
Run the REPL procedure from §2. Record the answer at the top of the
WORKLOG session entry. If the answer is "9 separate args", update
Step 6's IRCall emit accordingly.

### Step 1 — RED test
Create `test/test_t5_p6_persistent_dispatch.jl` per §4 / B §8. Add
`include` to `test/runtests.jl`. Run it.
**Expected RED**: all testsets fail at `reversible_compile: unknown
mem=...` or `_pick_alloca_strategy_dynamic_n undefined`.

### Step 2 — `LoweringCtx` fields + `lower()` kwargs
Add 4 fields: `mem::Symbol`, `persistent_impl::Symbol`,
`hashcons::Symbol`, `persistent_info::Dict{Symbol, PersistentMapImpl}`.
Backward-compat constructors default them. Thread kwargs through
`lower(parsed; ...)`.
**Check**: `Pkg.test()` still GREEN on every existing test — the new
fields default to `:auto` / `:linear_scan` / `:none` / `Dict()`.

### Step 3 — Dispatcher sibling + helpers
Add `_pick_alloca_strategy_dynamic_n(ctx, inst)`,
`_resolve_persistent_impl(impl, hashcons)`, `_state_len_bits(impl)`,
`_K_bits(impl)`, `_V_bits(impl)` below `_pick_alloca_strategy` in
`src/lower.jl`.
**Check**: RED test file's dispatcher-helper unit-test subsets pass.

### Step 4 — `lower_alloca!` extension
Split into const-n (unchanged byte-identical) and dynamic-n branches
per B §4.2. Dynamic-n branch:
- verifies `ctx.mem == :persistent` (else fail with hint);
- resolves impl;
- allocates `_state_len_bits(impl)` fresh wires (zero by WireAllocator
  invariant — no `pmap_new` IRCall for linear_scan);
- records `ctx.persistent_info[dest] = impl`;
- records `ctx.ptr_provenance[dest] = [PtrOrigin(...)]` so GEP
  walkers don't crash.
**Check**: test 1 `mem=:persistent` arm now fails at missing
`_lower_store_via_persistent!` instead of at `lower_alloca!`.

### Step 5 — Store + load helpers
Add `_lower_store_via_persistent!` + `_lower_load_via_persistent!`
per B §5.2/§5.3. Non-entry-block guard per B §5.2 (hard-error).
Multi-origin guard per B §R4 (hard-error).
**Check**: test 3 (diamond) hard-errors as `@test_throws` expects.

### Step 6 — Dispatcher wiring
Early-out in `_lower_store_single_origin!` (line 2098) and
`_lower_load_via_mux!` (line 1701): `if haskey(ctx.persistent_info,
alloca_dest)` → route to the persistent helpers BEFORE consulting
`alloca_info`.
**Check**: test 1 / test 2 now compile end-to-end (semantics may still
fail if register_callee! not yet added).

### Step 7 — Callee registration
Add `register_callee!(linear_scan_pmap_new/set/get)` at the end of
the register block in `src/Bennett.jl` (after line 209). Leave
`:okasaki`, `:hamt`, `:cf` registrations commented out with a
follow-up-bead note.
**Check**: test 2 (roundtrip) semantics GREEN against
`pmap_demo_oracle`.

### Step 8 — GEP / PtrOffset early-returns
Per B §5.5. Guard `lower_ptr_offset!` and `lower_var_gep!` to skip
flat-wire-slab logic when `haskey(ctx.persistent_info, base)`.
**Check**: test 2 still GREEN; no new failures.

### Step 9 — `reversible_compile` kwargs + `validate_persistent_config`
Per B §6.1. Three kwargs (`mem`, `persistent_impl`, `hashcons`) on
both `(f, arg_types)` and `(parsed::ParsedIR)` overloads. Thread
through to `lower(...)`. Implement A's `validate_persistent_config`
— at entry, when `mem=:persistent`, check that
`_resolve_persistent_impl(impl, hashcons)`'s callees are registered.
**Check**: all 6 testsets GREEN.

### Step 10 — SoftFloat wrapper threading
Add the three kwargs to the 3-arg SoftFloat wrapper at
Bennett.jl:268–295. Thread through to each
`reversible_compile(w, UInt64, ...)` call.
**Check**: `test_float_circuit.jl` byte-identical.

### Step 11 — Full regression
Run `Pkg.test()`. Every existing test must GREEN. Spot-check gate
counts from CLAUDE.md §6 + BENCHMARKS.md:

| Test | Byte-identical invariant |
|---|---|
| `test_increment.jl` i8 x+1 | total=100, Toffoli=28 |
| `test_int16.jl` | total=204, Toffoli=60 |
| `test_int32.jl` | total=412, Toffoli=124 |
| `test_int64.jl` | total=828, Toffoli=252 |
| `test_soft_fma` | 447,728 |
| `test_soft_exp_julia` | 3,485,262 |
| `test_soft_exp2_julia` | 2,697,734 |
| `test_shadow_memory.jl` W=8 | 24 CNOT |
| `test_universal_dispatch.jl` all lines 90–115 | symbols unchanged |
| `test_memory_corpus.jl` L10 | shadow_checkpoint unchanged |
| `test_persistent_interface.jl` `_ls_demo` | 436 / 90 Toffoli |
| `test_persistent_cf.jl` `_cf_demo` | 11,078 |
| `test_persistent_hashcons.jl` CF+Feistel | 65,198 |

Any drift → STOP, diff, investigate root cause (CLAUDE.md §6+§7).

### Step 12 — WORKLOG + BENCHMARKS + session close
- WORKLOG session entry: research-step answer, acceptance-test gate
  count baseline, any surprises during implementation, follow-up
  beads filed.
- No new BENCHMARKS.md row — T5-P6 is a dispatcher change. Pareto
  front numbers land in M5.7.
- File follow-up beads:
  - "T5-P6 extend: non-entry-block persistent stores via
    block-pred-guarded set"
  - "T5-P6 extend: wire `:okasaki` / `:hamt` / `:cf` arms"
  - "T5-P6 extend: wire `:naive` / `:feistel` hashcons"
  - "T5-P6 extend: parametric `max_n` via static upper-bound analysis"
  - "T5-P6 extend: multi-origin × persistent interaction"
  - (optional) "T5-P6 polish: rename `:persistent_tree` →
    `:persistent_map`"
- Close Bennett-z2dj.
- `git pull --rebase && git push` per CLAUDE.md session-close
  protocol.

---

## 6. Estimated line budget

- `src/lower.jl`: ~250 LOC (dispatcher sibling, lower_alloca!
  extension, 2 store/load helpers, GEP guards, LoweringCtx fields).
- `src/Bennett.jl`: ~30 LOC (3 kwargs ×2 overloads, SoftFloat wrapper
  threading, 3 `register_callee!` calls, `validate_persistent_config`).
- `test/test_t5_p6_persistent_dispatch.jl`: ~300 LOC.

Total: ~580 LOC added. One atomic commit per CLAUDE.md.

---

## 7. Risks (consensus summary)

From A+B, ordered by load-bearing-ness for MVP:

1. **NTuple-of-UInt64 aggregate in `lower_call!`** (B §12). Research
   step §2 resolves before code. #1 risk.
2. **Callee registration** — linear_scan_pmap_{new,set,get} not
   yet registered; A's `validate_persistent_config` mitigates with
   crisp error surface.
3. **False-path sensitization on non-entry persistent stores** — CLAUDE.md
   phi-resolution §. Mitigated by MVP hard-error.
4. **Multi-origin × persistent** — hard-errored in MVP.
5. **`max_n=4` silent clamp on linear_scan** — documented, follow-up
   for parametric max_n.
6. **State wire aliasing** (B §R5) — add a targeted assertion during
   implementation that `ctx.vw[alloca_dest]` and
   `ctx.vw[state_sym]` wire IDs diverge after `lower_call!`. Remove
   the assertion once the GREEN test stabilises.
7. **`test_persistent_interface.jl` baseline drift** — `_ls_demo`
   should NOT hit the new arm (uses direct Julia SSA, no alloca).
   Verify via `@code_llvm` once post-Step 2; if SROA folds it to an
   alloca+store chain, the 436 / 90 Toffoli baseline shifts — a
   proper regression signal.

---

## 8. Open questions deferred

- `:persistent_tree` vs `:persistent_map` naming — keep
  `:persistent_tree` in MVP.
- Whether `mem=:auto` eventually flips `:persistent` automatically for
  dynamic-n — M5.7 decision, not T5-P6.

---

End of consensus. Implementer follows §5 step-by-step, starting with
§2 research.
