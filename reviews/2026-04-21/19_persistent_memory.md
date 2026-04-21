# Persistent-Memory Subsystem — Review
**Reviewer**: specialist audit (persistent-DS jurisdiction)
**Date**: 2026-04-21
**Scope**: `src/persistent/*`, `src/shadow_memory.jl`, `src/softmem.jl`, `src/memssa.jl`, `test/test_persistent_*.jl`, `test/test_shadow_memory.jl`, `test/test_memssa*.jl`, `benchmark/sweep_persistent_*`, `docs/memory/*`, `docs/literature/memory/*`.

---

## Persistent-DS Comparison Table

LOC and test_LOC are raw `wc -l` counts (including headers, docstrings, and comments). "Gate count at demo (3-set + 1-get)" is the WORKLOG baseline at `optimize=true` where available (with `optimize=false` noted). "max_n supported" is the hard-coded demo-size — the non-parameterized production impls cannot take another value without source edits.

| Impl | src file | LOC | Tests (LOC) | max_n supported | Gate count (3-set+1-get demo) | Paper faithfulness | Recommendation |
|---|---|---:|---:|:---:|---:|---|---|
| linear_scan | `src/persistent/linear_scan.jl` | 110 | 86 (interface) | **4** hard-coded (`_LS_MAX_N`) | **436 / 90 Toffoli** (`optimize=true`); 6,350 at N=4 with K=max_n workload | N/A (baseline stub) | **KEEP as default** — the winner per 2026-04-20 sweep, O(1) per-set |
| okasaki_rbt | `src/persistent/okasaki_rbt.jl` | 397 | 114 | **4** hard-coded | **108,106 / 27,854 Toffoli** (Phase-3, optimize=true); ~356k w/ Feistel | Okasaki 1999 §2d balance faithful; delete DEFERRED (Kahrs 2001 not implemented) | **DEMOTE to optional** — 249× more gates than LS, no plausible win at Bennett's scale |
| hamt | `src/persistent/hamt.jl` | 309 | 158 | **8** hard-coded (`_HAMT_MAX_N`) | **96,788 / 25,576 Toffoli** (optimize=true); ~4.56M w/ Feistel | Bagwell 2001 §2 AMT faithful (single-level); HashCollisionNode and ArrayNode promotion BOTH deferred per design; delete NOT implemented | **DEMOTE to research artifact** — popcount alone ≥ 2,782 gates; cannot beat LS per cost model |
| cf_semi_persistent | `src/persistent/cf_semi_persistent.jl` | 385 | 173 | **4** hard-coded | **11,078 / 2,692 Toffoli** at K=3 (Phase-3 darling); **61,728 at K=max_n=4; 1.08M at N=16; 17.5M at N=64** — quadratic | CF 2007 Arr+Diff structure shape-faithful; the `ref`/`Diff` indirection collapsed into a flat NTuple (documented simplification); reroot implemented but **not on compile path** | **DELETE or relegate to documentation example** — Phase-3 win is a small-K artefact, quadratic at scale, buggy on reroot-with-key=0 overwrite |
| hashcons_feistel | `src/persistent/hashcons_feistel.jl` | 77 | (shared with jenkins: 208 LOC in hashcons test) | UInt32→UInt32 bijection | Standalone: ~thousands of gates. Layered CF+Feistel: **65,198**; HAMT+Feistel: 4,562,820 | Luby-Rackoff 1988 4-round; rotations {1,3,5,7} match `src/feistel.jl` | KEEP — cheap hash, bijection property genuinely useful; production impl in `src/feistel.jl` emits gates directly |
| hashcons_jenkins | `src/persistent/hashcons_jenkins.jl` | 100 | (shared) | UInt32→UInt32 mix | Standalone >100 gates; CF+Jenkins 83,898; HAMT+Jenkins 4,581,520 | Mogensen 2018 Fig.5 p.217 verbatim port of 18-op Jenkins-96 mix | **DEMOTE** — 28% more gates than Feistel on every combo, no observable advantage |
| popcount | `src/persistent/popcount.jl` | 72 | within HAMT test | 32-bit | **2,782 / 1,004 Toffoli** standalone | Bagwell 2001 Fig.2 p.3 verbatim C port | KEEP — only used by HAMT; would die if HAMT dies |
| harness | `src/persistent/harness.jl` | 109 | — | N/A | N/A | N/A | KEEP — but extend with persistent-invariant tests (see H-3) |
| interface | `src/persistent/interface.jl` | 80 | — | N/A | N/A | N/A | KEEP |
| shadow_memory | `src/shadow_memory.jl` | 115 | 135 | any (gate-level) | 3W/store + W/load | Enzyme-adapted | KEEP — orthogonal primitive, not a persistent map |
| softmem (MUX EXCH) | `src/softmem.jl` | 305 | 94 + 53 + 102 | N·W ≤ 64 | callee-based, ~constant per shape | — | KEEP — unrelated to persistent; MUX-EXCH tier |
| memssa | `src/memssa.jl` | 164 | 95 + 124 | N/A | analysis only | LLVM print<memoryssa> parser | KEEP — orthogonal analysis |

**Totals for the persistent-DS subtree only** (`src/persistent/`):
- src LOC: 1,856
- test LOC: 739
- Winner by 2026-04-20 sweep: `linear_scan`

**Maintenance debt**: 4 impls (okasaki, hamt, cf, linear_scan) × 2 hash layers = 6 layered combos. 5 of 6 are almost certainly dead code in any real user path post-T5-P6.

---

## Executive Summary (10 bullets)

1. **The subsystem is over-built for what T5-P6 will need.** Five persistent-DS impls exist; the empirical sweep + cost-model argument has already concluded `linear_scan` will be the default and the others are between 10× and 700× worse. The Phase-3 "CF wins" finding was a measurement artefact (K=3 fixed inserts hid CF's quadratic per-set cost).

2. **No persistent-map function is registered as a callee.** `register_callee!` is called for every `soft_mux_*`, `soft_fadd`, etc., but NOT for `linear_scan_pmap_*`, `okasaki_pmap_*`, `hamt_pmap_*`, or `cf_pmap_*`. Demos work by inlining the full body into the outer function. T5-P6 will need to register these — currently everything relies on extraction-time inlining, not the callee protocol the PRD claims (`persistent.jl` header: "register_callee! — no direct gate emission").

3. **Hash-consing collision policy is silent overwrite everywhere.** Feistel (claimed bijection on UInt32) is NOT bijective on the Int8 subset after low-byte truncation (`soft_feistel_int8` test accepts `>200` distinct images out of 256, not 256). HAMT uses 5-bit hash where Int8(0) and Int8(32) collide; the impl overwrites silently. The "perfect hash" claim in `hashcons_feistel.jl:16` is therefore **false for the `_int8` wrapper** actually used in the demos.

4. **`cf_reroot` has a demonstrable correctness bug for key=Int8(0) overwrites.** The impl uses `r_key == 0` as sentinel for "empty slot" (line 355) to decide whether to decrement `arr_count`. But Int8(0) is a *valid* protocol key. An overwrite of key=0 records `old_k=0` in Diff; reroot then incorrectly decrements `arr_count`, making the preceding non-zero-keyed slot inaccessible on subsequent lookups. Not tested. Doesn't affect the compile path (reroot is informational only) but **lies about the C-F correspondence claim** in the same file's §5 commentary.

5. **`verify_pmap_correctness` in the harness is weak.** Uses default keys `K(1):K(max_n)` — never tests key=0, never tests the persistent-update invariant (`pmap_get(old_state, k)` after `new = pmap_set(old, k, v)`), never tests overflow past max_n, never compares impls against each other (a Dict oracle is the only check). Contract §20-§25 of `interface.jl` is only partially verified.

6. **Sweep reproducibility is structurally fine but under-witnessed.** `benchmark/sweep_cell.jl` + `codegen_sweep_impls.jl` + subprocess isolation + JSONL append is sound methodology. But `sweep_persistent_results.jsonl` has only 8 rows (5 LS + 3 CF), HAMT and Okasaki are **not empirically parameterized at scale** — the "HAMT/Okasaki also lose" conclusion rests entirely on a cost-model argument (popcount ≥ 2,782 gates alone) rather than measurement.

7. **HAMT overflow past max_n=8 silently drops data.** When the 9th distinct hash is inserted, `idx` can be 8, which matches no slot in the compile-time-unrolled 0..7 chain. `nk7_ins = ifelse(idx==7, k, ifelse(idx<7, k6, k7)) = k7` — the new key never lands anywhere. The comment "behaviour is impl-defined per protocol" papers over what is actually silent state corruption, violating Principle 1 (fail fast, fail loud) in CLAUDE.md.

8. **Okasaki delete is DEFERRED; Kahrs 2001 never implemented.** Documented in `okasaki_rbt.jl:39-45` as deferred to Bennett-cc0.1. Paper faithfulness gap: the impl is insert+lookup only. This is acceptable if we're deleting Okasaki outright (recommended), unacceptable if we're keeping it.

9. **T5-P6 interface will not need another refactor — but the impls do.** `PersistentMapImpl` struct is sufficient as a bundle. The dispatcher design in `p6_proposer_A.md` cleanly adds a `:persistent_tree` symbol parallel to `:shadow_checkpoint`. However, the production impls use hard-coded `_LS_MAX_N=4`, `_HAMT_MAX_N=8`, etc. — they cannot absorb a dynamic alloca's runtime size. T5-P6 will need to use the `benchmark/codegen_sweep_impls.jl` pattern (or equivalent), NOT the `src/persistent/*.jl` production files directly.

10. **`softmem.jl` and `shadow_memory.jl` are NOT overlapping.** Despite the name similarity, they do different things: `softmem.jl` is MUX-EXCH callees for static-shaped packed arrays; `shadow_memory.jl` is a wire-level primitive for universal fallback. Both live outside the persistent-DS subsystem. Neither is dead code.

---

## Prioritized Findings

### CRITICAL

**C-1. `hamt_pmap_set` drops data silently when hashing past max_n=8.**
File: `src/persistent/hamt.jl:230-236`
With 8 filled slots and a 9th distinct-hash insertion, `idx` computes to 8 (popcount of 8 set bits below the new one). The unrolled chain checks `idx == 0..7`; `idx == 8` matches no slot; slot 7's `nk7_ins` evaluates to `k7` (preserved). The new key is **silently lost**, bitmap still mutated to include the new bit. Subsequent `hamt_pmap_get` for the 9th key uses `idx=8` on lookup, accumulator stays 0, returns miss. The data isn't corrupted *per se* but the bitmap is now inconsistent with the compressed array (bit set but no entry). This violates CLAUDE.md Principle 1. Either clamp like linear_scan does, or assert/error in pure-Julia.

**C-2. `cf_reroot` uses key=0 as empty-slot sentinel, breaking overwrite-reroot for key=Int8(0).**
File: `src/persistent/cf_semi_persistent.jl:350-357`
```julia
new_count = ifelse(depth == UInt64(0),
                   count,
                   ifelse(r_key == UInt64(0),
                          ifelse(count > UInt64(0), count - UInt64(1), UInt64(0)),
                          count))
```
Conflates "slot was never allocated" with "slot held key=0". Sequence `set(0,99) → set(0,42) → reroot` should leave slot 0 = (0, 99) with count=1; instead leaves count=0 and makes key=0 unreachable. Reroot is not on the compile path (Bennett's reverse handles it), so this is an isolated-correctness concern, but the file's own §5 correspondence argument relies on reroot being correct. The bug is a silent lie about the Diff-chain ↔ Bennett-tape equivalence.

**C-3. "Perfect hash" claim for `soft_feistel_int8` is false.**
File: `src/persistent/hashcons_feistel.jl:14-17, 69-77`
Feistel is a bijection on UInt32→UInt32 (Luby-Rackoff). `soft_feistel_int8` zero-extends Int8→UInt32, runs Feistel, then **truncates to the low byte** and reinterprets as Int8. Truncation destroys bijectivity. The test `test_persistent_hashcons.jl:158` explicitly acknowledges this with `@test length(images) > 200` (NOT 256). Yet the comment line says "perfect hash — no collisions." Documentation lies. Fix: retitle the `_int8` wrapper as "uniformising hash (not perfect on Int8 due to truncation)" and update the HAMT+Feistel analysis that inherits this assumption.

### HIGH

**H-1. No persistent-map function is `register_callee!`-ed.**
File: `src/Bennett.jl:163-208`
Every soft-* and soft_mux_* is registered; none of `linear_scan_pmap_*`, `okasaki_pmap_*`, `hamt_pmap_*`, `cf_pmap_*` are. The test demos work because they inline. The PRD and the `persistent.jl` module comment both claim the callee pattern is used ("compiles via `register_callee!` — no direct gate emission"). This claim is **factually wrong** for the current state. T5-P6 will have to add these; doing so will change gate counts from the reported baselines (inlined-body compilation collapses more aggressively than callee-extracted compilation).

**H-2. HAMT and Okasaki are NOT parameterized at scale; the "cost-model argument" is unwitnessed.**
File: `benchmark/sweep_persistent_summary.md:33-34`
> "HAMT | * | not parameterized — using Phase-3 baseline at max_n=8"
> "Okasaki | * | not parameterized — using Phase-3 baseline at max_n=4"
The 2026-04-20 sweep writeup says HAMT and Okasaki "cannot be cheaper per-set than LS because their per-set work strictly includes more arithmetic." This is a cost-model inference, not a measurement. The documented recommendation ("linear_scan as the default") rests on measured CF blowup (which IS documented) PLUS unmeasured HAMT/Okasaki. This is a defensible engineering decision — but the summary should flag the distinction honestly: "LS beats CF empirically to N=1000; LS plausibly beats HAMT/Okasaki per cost-model, unconfirmed at scale."

**H-3. `verify_pmap_correctness` does not test the persistent-update invariant.**
File: `src/persistent/harness.jl:43-87`
The protocol contract in `interface.jl:19-24` explicitly lists four semantic invariants. The harness checks #1, #2, #3 but **does not check** that `pmap_set` returns a new state while the old state is unchanged. For NTuple-based impls this is trivially true (NTuples are immutable), so it's test coverage for a structural invariant — but if T5-P6 introduces mutable state (e.g. a Ref-backed impl for performance), this invariant can break silently. Add a test: `state2 = pmap_set(state1, k1, v1); @test pmap_get(state1, k1) != v1` (assuming state1 was empty or had a different value).

**H-4. `verify_pmap_correctness` never tests key=0 (the problematic value).**
File: `src/persistent/harness.jl:38` — default keys are `K(1):K(max_n)`. Given C-2's reroot bug and the general "zero-as-sentinel" pattern recurring across impls, this is the single most important missing test. Add: test with all-zero keys, mixed-zero keys, and the interleave `set(0,v); set(k,v'); get(0)` to shake out in_use-guard bugs.

**H-5. `hashcons_feistel.jl` and `hashcons_jenkins.jl` naming collision risk.**
Both define `soft_feistel32` / `soft_feistel_int8` vs. `soft_jenkins96` / `soft_jenkins_int8`, both exported, both in the `Bennett` module namespace. But `src/feistel.jl` also defines `emit_feistel!` for the gate-level impl. The pure-Julia `soft_feistel32` (hashcons_feistel.jl) and the gate-level `emit_feistel!` (feistel.jl) are conceptually the same Feistel network, but they share no code. A user reading the module exports will see two Feistel-related names (`soft_feistel32`, `soft_feistel_int8`) and must infer the gate-level version is referenced only inside `src/lower.jl`. Documentation should point this out explicitly.

### MEDIUM

**M-1. Okasaki delete is deferred; paper faithfulness partial.**
File: `src/persistent/okasaki_rbt.jl:39-45`
"DELETE: DEFERRED — Kahrs 2001 delete requires `app`... deferred to a follow-up bead (Bennett-cc0.1)." If keeping Okasaki, this is a ~200-LOC implementation task. If deleting (recommended), this section is moot.

**M-2. HAMT is single-level only; no HashCollisionNode; no ArrayNode promotion.**
File: `src/persistent/hamt.jl:17-31`
Documented as a simplification. Means the "log32 N" asymptotic claim never materialises — this is effectively a bitmap-compressed linear scan over 32 slots with unused capacity bits. The impl's `max_n=8` choice (rather than 32) is further admission: 8 is the usable range where popcount indices are meaningful but state fits in 17 UInt64s.

**M-3. CF `cf_reroot` is dead code on the compile path.**
File: `src/persistent/cf_semi_persistent.jl:320-372`
Documented as "implemented for correspondence verification, not called by pmap_get, Bennett's reverse handles the undo." 52 LOC of reversible logic that ships but never executes in compiled output. If deleting CF (recommended), this vanishes; if keeping, the comment should be hoisted higher so future agents don't assume `cf_reroot` matters for runtime correctness.

**M-4. The `_LS_MAX_N = 4` hard-coding is sweep-time duplicated.**
The production `src/persistent/linear_scan.jl` uses `_LS_MAX_N = 4` hard-coded; the sweep `benchmark/codegen_sweep_impls.jl` + `sweep_persistent_impls_gen.jl` produces a separate family at each max_n. Two parallel sources for linear_scan code. WORKLOG notes T5-P6 will likely use the codegen pattern. Recommendation: during T5-P6, delete the hard-coded `src/persistent/linear_scan.jl` in favour of a generator function exported publicly.

**M-5. `verify_reversibility(c; n_tests=3)` is sparse for 7-arg Int8 demos.**
File: `test/test_persistent_*.jl` — every test calls `verify_reversibility(c; n_tests=3)` where 3 random inputs are tested. Given the vast input space (2^56 for 7 Int8 args), 3 tests catch only crashes and gross mis-compilation, not subtle bugs like the hash-collision edge cases. Per CLAUDE.md §4 "Exhaustive verification", this is strictly fewer than the i8 arithmetic functions that test all 256 inputs. Bump n_tests to 30+ for persistent demos; they're cheap (already compiled).

**M-6. `cf_pmap_set` clamps depth and count on overflow but still increments state.**
Files: `src/persistent/cf_semi_persistent.jl:199-201, 209-211, 252-258`
Both `safe_depth` and `target_slot` clamp to max_n-1 on overflow. Combined with the "latest-write wins on overwrite at first match" semantics, the max_n+1-th insertion of a NEW key silently overwrites slot max_n-1 and pushes to diff entry max_n-1, losing information. Same silent-corruption critique as C-1 for HAMT.

### LOW

**L-1. `linear_scan_pmap_*` functions are NOT exported publicly.**
File: `src/Bennett.jl:38` — only `LINEAR_SCAN_IMPL` is exported. Tests use `Bennett.linear_scan_pmap_new()` (qualified access). `HAMT_IMPL`, `CF_IMPL`, `OKASAKI_IMPL` are exported with their functions. Inconsistent with other impls. If you delete CF/HAMT/Okasaki (recommended), the inconsistency goes away; otherwise add LS exports.

**L-2. Popcount standalone gate count (2,782) is not propagated into the dispatcher design discussion.**
File: `docs/memory/persistent_ds_scaling.md:140-147`
The number is the lynchpin of the "HAMT can't win" argument, but it appears only in one doc and in the HAMT test's `@info` line. Should be a WORKLOG regression baseline (per CLAUDE.md Principle 6) so that changes to `popcount.jl` — which happens rarely but catastrophically — trip a regression signal.

**L-3. `hashcons_jenkins.jl` header comment says "24 mix operations" but the body has 18.**
File: `src/persistent/hashcons_jenkins.jl:5, 62-81`
Line 5: "24-instruction Jenkins reversible mix function". Line 62 comment: "The 18 mix operations from Mogensen p.217–218 Fig 5." The first two XORs (lines 58-59) count as lines 1-2 of the 20-line Mogensen pseudocode; 18 more in the body = 20 total, not 24. The "24" claim is wrong. Fix or clarify (Mogensen's paper may count some single-line ops as 2 ops).

**L-4. `_hashcons_oracle` helper function uses `Dict{Int8, Int8}` as oracle.**
File: `test/test_persistent_hashcons.jl:119-125`
The oracle dedupes by hashed-key equality. But since `soft_feistel_int8` is NOT a bijection on Int8 (see C-3), two distinct source keys can hash to the same Int8 image, causing the oracle to lose information — and the same happens in the compiled circuit. Test coincidentally passes because hash collisions are rare in the sampled inputs + fixed RNG seed `20260417`. Change the seed and test flakes. File: fix C-3 or add a comment here that the oracle shares the compile bug, so they "agree" by shared misbehavior.

**L-5. `test_persistent_hamt.jl` has a testset ordering dependency.**
File: `test/test_persistent_hamt.jl:55-57`
Uses `import Random; Random.seed!(rng_seed)` mid-testset. `import` inside a testset body is legal Julia but unusual. If this file runs a second time in the same session (common during `Pkg.test()`), `Random` is already imported; harmless. If Random's default RNG state differs across tests, results differ. Minor hygiene issue.

**L-6. `test_persistent_hashcons.jl:20` comment admits RNG seed is protecting a latent bug.**
> "Fixed seed picks a trial sequence that avoids these collision edges."
Tests that pass because of a magic seed are a red flag. If `Random.seed!(20260417)` is removed, tests fail. The "collision edges" it dodges are exactly the HAMT low-5-bit × Feistel-truncation collision problem.

### NIT

**N-1. `src/persistent/persistent.jl` include order**
Does: `interface`, `linear_scan`, `okasaki_rbt`, `cf_semi_persistent`, `harness`, **`popcount`**, `hamt`, `hashcons_jenkins`, `hashcons_feistel`.
`harness.jl` is after linear_scan but before hamt. `popcount.jl` is AFTER harness. The harness cannot test HAMT's popcount if HAMT hasn't loaded yet — but it doesn't need to, it's a pure-Julia trait interface. Still, `popcount` should load before `hamt` (which uses it). Currently works because Julia resolves at runtime, but the ordering is confusing. Move `popcount.jl` before `hamt.jl` (it's actually in the right place per the list, but `harness.jl` at line 13 is sandwiched between CF and popcount — odd placement since harness doesn't need popcount).

**N-2. Benchmark directory has 5 hand-written `bc*.jl` scripts plus 3 sweep scripts plus `codegen_sweep_impls.jl` plus an 18k-LOC auto-generated file.**
`benchmark/sweep_persistent_impls_gen.jl` is 17,815 LOC (generated, checked in). This bloats repo size and diff noise for unrelated changes. Recommend `.gitignore`-ing generated files; generate on-demand in CI.

**N-3. Inconsistent naming: `hamt_log32` vs `okasaki_rbt` vs `cf_semi_persistent` vs `linear_scan`.**
Interface names: `HAMT_IMPL.name = "hamt_log32"`, `OKASAKI_IMPL.name = "okasaki_rbt"`, `CF_IMPL.name = "cf_semi_persistent"`, `LINEAR_SCAN_IMPL.name = "linear_scan"`. These strings are surfaced in error messages and should be stable. The "log32" suffix on HAMT is aspirational — as noted in M-2 the impl is actually single-level. Consider "hamt_bitmap_8" (honest) or drop the suffix.

---

## Reversibility-Hygiene Audit (per-impl)

| Impl | Has test for `verify_reversibility`? | Has ancilla-leak test? | Verified by `verify_pmap_correctness`? |
|---|:---:|:---:|:---:|
| linear_scan | yes (`test_persistent_interface.jl:51`) | no (relies on Bennett construction) | yes |
| okasaki_rbt | yes (`test_persistent_okasaki.jl:67`) | no | yes |
| hamt | yes (`test_persistent_hamt.jl:68, 124`) | no | yes |
| cf_semi_persistent | yes (`test_persistent_cf.jl:132`) | no | yes |
| hashcons_feistel (standalone) | yes (`test_persistent_hashcons.jl:141`) | no | N/A (not a pmap) |
| hashcons_jenkins (standalone) | yes (`test_persistent_hashcons.jl:131`) | no | N/A |
| popcount | yes (`test_persistent_hamt.jl:66`) | no | N/A |

**`verify_reversibility(c; n_tests=3)` is used uniformly, but `n_tests=3` is paltry for 7-arg Int8 demos.** Bennett's reversibility invariant guarantees that IF `verify_reversibility` returns true on ANY input, the circuit is reversible — that's a Bennett construction property. So `n_tests=3` is actually sufficient FOR the reversibility property. BUT — ancilla-cleanup correctness (all ancillae return to zero) is also checked, which is per-input; 3 inputs out of 2^56 is 3e-17 coverage. Bennett's construction makes this a structural invariant of `bennett()`, not per-input, so the low coverage is again probably safe. Still, this should be documented rather than implied.

No impl has an **explicit** ancilla-leak test (e.g. `@test all(ancilla_wires .== 0)` after simulation). The claim is that `verify_reversibility` implies ancilla-zero via Bennett's construction.

---

## Paper Faithfulness — Cites

| Impl | Paper | Section cited | Visible in code at | Verdict |
|---|---|---|---|---|
| okasaki_rbt | Okasaki 1999 JFP 9(4):471 §2d | `src/persistent/okasaki_rbt.jl:1, 269-303` | 4 balance cases LL/LR/RL/RR with bodies matching paper's §2d §2e (paper's "or-pattern-collapsed" is split into 4 cases for branchless MUX) | Faithful; delete deferred |
| hamt | Bagwell 2001 "Ideal Hash Trees" LAMP-2001-001 §2 | `src/persistent/hamt.jl:1-31` | Single-level AMT with bitmap; no HashCollisionNode per design | Partial — insert algorithm is ad hoc (paper has prose, not pseudocode; see `bagwell_hamt_brief.md` note on MISSING algorithm pseudocode) |
| cf_semi_persistent | Conchon-Filliâtre 2007 ML Workshop §2.3 | `src/persistent/cf_semi_persistent.jl:1-106` | `Arr` + `Diff` structure flattened into NTuple; `ref` indirection explicitly abandoned | Shape-faithful; claims §5 correspondence but `cf_reroot` buggy (C-2) |
| popcount | Bagwell 2001 Fig.2 p.3 (C code) | `src/persistent/popcount.jl:10-17, 57-72` | Verbatim 5-line port, explained with masks | Faithful |
| hashcons_jenkins | Mogensen 2018 NGC 36:203 Fig.5 p.217-218 | `src/persistent/hashcons_jenkins.jl:1-46, 57-84` | 18-op mix (not 24 as header claims — L-3) | Faithful minus arithmetic error in comment |
| hashcons_feistel | Luby-Rackoff 1988; Bennett.jl `src/feistel.jl` | `src/persistent/hashcons_feistel.jl:1-17` | 4-round Feistel, rotations {1,3,5,7} | Faithful; "perfect hash" claim is misleading (C-3) |

---

## T5-P6 Dispatcher Readiness

The interface is **flexible enough** for T5-P6, per `p6_proposer_A.md`'s design:
- `PersistentMapImpl` struct is a bundle the dispatcher can select by name.
- Adding `:persistent_tree` symbol parallel to `:shadow_checkpoint` (precedent: M3a) doesn't require signature churn.
- `PersistentConfig` kwarg is orthogonal to existing dispatch.

**But it will need a refactor of the impls themselves**:
1. **Hard-coded max_n must go.** `_LS_MAX_N=4` in the production impl vs. parameterized `sweep_ls_*` in the codegen. T5-P6 will compile linear_scan at whatever N the user's alloca needs. Either delete `src/persistent/linear_scan.jl` and promote `benchmark/codegen_sweep_impls.jl` into `src/`, or add an `@generated` wrapper (which triggered `LLVMGlobalAlias` and TLS-allocator gaps per WORKLOG — so plain codegen is the safer path).
2. **Callee registration must happen.** Currently the `register_callee!` machinery expects a top-level function with a stable type signature; per-N linear_scan impls will need one registration per shape.
3. **Soft_feistel_int8 bijection claim must be corrected or the hashcons arm is wrong by construction.**
4. **Hard-error unsupported-impl cases.** Currently `okasaki`/`hamt`/`cf` all compile; T5-P6 MVP per WORKLOG `2026-04-21` is linear_scan-only. The other symbols should error loudly with "NYI" pending a later bead, not fall through to an untested path.

---

## Sweep Reproducibility

**Methodology**: sound.
- Subprocess-per-cell: kills only the OOMed cell.
- JSONL append: partial progress survives crashes.
- Plain-Julia codegen (not `@eval`/`@generated`): dodges `cc0.3`/`cc0.5` LLVM gaps.

**Reproducibility risk**: 
- Script runs `reversible_compile(..., optimize=false)` — the `optimize=false` flag is load-bearing and documented. Good.
- `include(joinpath(@__DIR__, "sweep_persistent_impls_gen.jl"))` loads an 18k-LOC auto-generated file. The generator `codegen_sweep_impls.jl` is checked in, so reproducibility is intact.
- The `jsonl` results file is 8 rows — easy to verify by re-running.

**Did not attempt to re-run the sweep** (per reviewer scope). Would be a useful P0 follow-up for the T5-P6 team.

**Limitations acknowledged in `sweep_persistent_summary.md` §Limitations**:
1. HAMT/Okasaki NOT parameterized at scale (ack).
2. K=max_n workload (ack).
3. optimize=false (ack).
4. Compile time at max_n=1000 is 2 min (ack).

These are good-faith disclosures. The "recommendation: linear_scan default" is epistemically appropriate given (1).

---

## `shadow_memory.jl` vs `softmem.jl` vs Persistent-DS — Architecture Clarification

Three separate mechanisms, easily confused by name:

- **`src/shadow_memory.jl`** (115 LOC): *wire-level* primitive. `emit_shadow_store!(gates, wa, primal, tape, val, W)` emits 3W CNOTs to a Vector{ReversibleGate}. Direct gate emission. Universal fallback for any shape. Enzyme-adapted.

- **`src/softmem.jl`** (305 LOC): *callee-level* MUX-EXCH primitives. `soft_mux_store_4x8(arr::UInt64, idx::UInt64, val::UInt64)::UInt64` is a pure-Julia branchless function. Bennett.jl compiles it via `register_callee!` pipeline, same as `soft_fadd`. Packed arrays only (N·W ≤ 64).

- **`src/persistent/*`**: *callee-level* persistent-DS primitives. Same pattern as softmem but with persistent (history-preserving) semantics. NOT currently `register_callee!`-ed (H-1).

**Dispatcher picks between these** (`_pick_alloca_strategy` in `src/lower.jl:2084`):
- `:shadow` → `src/shadow_memory.jl` (static idx, any W).
- `:mux_exch_NxW` → `src/softmem.jl` (dynamic idx, N·W ≤ 64).
- `:shadow_checkpoint` → hybrid wire-level (N·W > 64, static-sized).
- `:persistent_tree` (proposed T5-P6) → `src/persistent/*` (dynamic-sized, runtime alloca).

No overlap. No dead code. The naming is legit but confusing for newcomers; a 5-line `src/persistent/README.md` (or inline module docstring) stating "this is the persistent-DS tier, distinct from shadow_memory.jl and softmem.jl" would help.

---

## MemorySSA Integration — Independence Assessment

`src/memssa.jl` (164 LOC) is **orthogonal to persistent maps**. It provides an IR-annotation parser for LLVM's `print<memoryssa>` pass output, exposing Def/Use/Phi graphs. Used by `ir_extract.jl` (`use_memory_ssa=true` kwarg) for shape inference on allocas.

Persistent-maps don't use MemorySSA at all. The test `test_memssa_integration.jl` tests the extraction; `test_memssa.jl` tests the parser. Self-contained tier.

Would be used by T5-P6 only indirectly: alloca-shape inference decides whether to dispatch to `:persistent_tree`, and MemorySSA helps clean up the IR before that decision. No persistent-map impl depends on it.

---

## End-of-Life Recommendation

### Delete

- **`src/persistent/cf_semi_persistent.jl`** (385 LOC)
  - Quadratic per-call in max_n (measured to N=64 blowing to 17.5M gates).
  - `cf_reroot` has a buggy key=0 overwrite case (C-2), not on compile path.
  - Tests assert correspondence with Bennett tape but that correspondence is only structural, not gate-count-advantageous.
  - CF+Feistel at 65,198 gates is beaten by LS alone at 6,350.
  - Evidence: `benchmark/sweep_persistent_summary.md` per-set table; CF/set at N=64 is 272,791 vs LS/set at 1,395 (196× worse).

- **`src/persistent/okasaki_rbt.jl`** (397 LOC)
  - 249× more gates than LS on the baseline demo (108k vs 436).
  - Delete is deferred; would add ~200 more LOC if completed.
  - Balance-dispatch pays full 4-way cost on every insert by branchless design.
  - No empirical refutation of the "HAMT/Okasaki can't beat LS" cost-model.
  - Evidence: Phase-3 numbers in WORKLOG 2026-04-17 session log.

- **`src/persistent/hamt.jl`** (309 LOC) + **`src/persistent/popcount.jl`** (72 LOC, HAMT-only consumer)
  - 222× more gates than LS (96,788 vs 436).
  - popcount itself is 2,782 gates — higher than LS's ENTIRE per-set.
  - HAMT+Feistel = 4,562,820 gates — absurd for a 4-key demo.
  - Single-level impl abandons the paper's asymptotic advantage.
  - Silent data-drop on overflow past max_n=8 (C-1).
  - Evidence: cost-model argument in `docs/memory/persistent_ds_scaling.md:132-147`.

- **`src/persistent/hashcons_jenkins.jl`** (100 LOC)
  - 28% more gates than Feistel on every DS combo (WORKLOG 2026-04-17 Phase-4 table).
  - Arithmetic inconsistency in comments (L-3).
  - Retains academic interest (Mogensen 2018) but zero functional advantage.
  - Keep the *paper brief* (`docs/literature/memory/mogensen_hashcons_brief.md`); delete the impl.

**Total deletion**: 1,263 LOC of src + 208 LOC of test (hashcons tests remain for Feistel alone; Okasaki/HAMT/CF tests drop) ≈ 1,500+ LOC removed.

### Keep

- **`src/persistent/linear_scan.jl`** — the winner; production default.
- **`src/persistent/hashcons_feistel.jl`** — cheapest hash; keep with C-3 fix.
- **`src/persistent/interface.jl`** — bundle type; needed by T5-P6.
- **`src/persistent/harness.jl`** — correctness self-test; extend with H-3, H-4.

### Merge/Refactor

- **Promote `benchmark/codegen_sweep_impls.jl` into `src/persistent/linear_scan_codegen.jl`** (M-4). T5-P6 needs dynamic-N linear_scan; the codegen already exists.
- **Rename `softmem.jl` → `src/mux_exch/` subdirectory** for clarity (optional, nice-to-have). Not urgent.

### Justification for the radical cut

CLAUDE.md Principle 11 (PRD-driven development): "Don't implement features not in the current PRD." The T5 PRD names four impls because it expected HAMT/Okasaki/CF to win. The 2026-04-20 sweep overturned that expectation. The impls remain as research optionality — but per CLAUDE.md Principle 7 ("bugs are deep and interlocked") each kept impl is a maintenance surface with subtle bugs (C-1, C-2, C-3 demonstrate three separate ones in the three losing impls). The cheapest path to reduce correctness risk is deletion.

If the project wants to preserve "research optionality", do so in a branch, not on main. Alternatively, move `okasaki_rbt.jl`, `hamt.jl`, `cf_semi_persistent.jl` to a `src/persistent/research/` subdirectory with its own test file that's *not* in `runtests.jl` — available for opt-in benchmarking but not a gate on the main test suite.

---

## Appendix: Suggested Test Additions (for whichever impls survive)

1. **Persistent-update invariant** (H-3): after `s2 = set(s1, k, v)`, verify `get(s1, k) != v` when s1 didn't have k.
2. **key=0 overwrite** (H-4, addresses C-2): `s = set(new(), 0, 99); s2 = set(s, 0, 42); @test get(s, 0) == 99; @test get(s2, 0) == 42`.
3. **Overflow-past-max_n** (C-1): set max_n+1 distinct keys, verify the first max_n are still recoverable OR an error is thrown.
4. **Hash-collision witness** (C-3): pairs of Int8 with the same `soft_feistel_int8(k)` — prove collisions exist.
5. **Gate-count regression anchor** for popcount (L-2): `@test gate_count(reversible_compile(soft_popcount32, UInt32)).total == 2782` with a ±5% tolerance.
6. **Exhaustive pure-Julia** for max_n=4: all 4!·(2^4)^4 ≈ 100k combinations for 2-key subsets. Cheap, catches latent bugs.

These tests should be RED against current code for C-1, C-2, C-3.
