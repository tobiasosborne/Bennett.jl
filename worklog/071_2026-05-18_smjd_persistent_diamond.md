## Session log — 2026-05-20 — Bennett-2uas T5-P7b docs pass (closes T5 epic)

**Shipped:** Four deliverables — docs only, no source/test changes.

1. **BENCHMARKS.md** — new `## Persistent-DS head-to-head Pareto (T5-P7a)` subsection
   with the 12-row green-cells table (all numbers read directly from
   `benchmark/bc_t5_head_to_head_results.jsonl`), error-cell explanations (Bennett-7sb7
   for HAMT/optimize=false, Bennett-8o70 for wide-W), verdict table (linear_scan wins
   every cell, flat in depth), and an optimize-regime note. Critical-path status list
   updated: T5-P6 and T5-P7a/b promoted from ◐/○ to ✓.

2. **Worklog** — This entry. All P5/P6/P7 chain entries were already present:
   P5 in worklog/030 (lmkb+f2p9), P6 in worklog/070 (z2dj) + worklog/071
   (smjd/6883/d746/qi6c entries), P7a in worklog/071 (ktt8 entry). Only gap was
   the P7b docs session itself — this entry.

3. **docs/paper_outline_T5.md** (NEW) — §T5 section for Bennett-6siy. Bullet-outline
   structure covering: central contribution (tiered per-alloca-site dispatch),
   Enzyme framing table, §T5 section outline (intro/prior work/MemorySSA
   approach/tiered dispatch/benchmarks/conclusion), T5-P7a headline numbers,
   data-source annotations for final-draft verification. No prose beyond framing
   paragraphs and section descriptions.

4. **README.md** — (a) Persistent-DS row added to the memory strategies table with
   gate counts and `persistent_impl` kwarg docs. (b) Two new bullet points in
   "Wider types and composability": persistent-DS fallback + multi-language ingest
   (`extract_parsed_ir_from_ll` / `extract_parsed_ir_from_bc`). (c) T5 active
   workstream updated from "P6 is the current frontier" to "T5 complete as of
   2026-05-20" + open follow-ups list.

**Gotchas / Lessons:**

1. **BENCHMARKS.md critical path list had T5-P6 marked ◐ (in_progress) and T5-P7 as ○ (future).** All of z2dj/smjd/6883/d746/qi6c/ktt8 were closed BEFORE this docs pass — the status list was just stale. Updated to ✓ entries with accurate descriptions. **Take-home:** when a chain of beads closes sequentially over multiple sessions, the docs file that lists them can drift by 3–4 sessions before a dedicated docs pass catches up. Schedule a docs pass as the named deliverable of the final epic bead (as T5-P7b was), not as an afterthought.

2. **README T5 section said "in progress" for an epic closed weeks prior.** The "T5 — persistent hash-consed heap (in progress)" phrasing was last updated mid-P6; by P7b the wording was stale. Updated "T5 epic (in progress)" → "T5 epic (complete as of 2026-05-20)".

3. **No paper outline file existed yet for Bennett-6siy.** Searched `docs/`, `docs/prd/`, `docs/design/`, and root — only references in `Bennett-Memory-PRD.md` and worklog entries. Created `docs/paper_outline_T5.md` as a standalone §T5 section per the bead spec.

**Verification:**
- All gate counts in the BENCHMARKS table were read verbatim from `benchmark/bc_t5_head_to_head_results.jsonl` (each `ok:true` line).
- The only `ok:true` cells are the 12 rows above (linear_scan/okasaki/cf × W=8 × depth ∈ {3,8,32,128}).
- Error-cell counts verified from jsonl: hamt W=8 depth∈{3,8,32} = 3 cells with the j_print_to_string error; hamt W=8 depth=128 = 1 cell with demo-not-pre-generated error; W∈{16,32,64} all impls = 48 cells with Int8-only error (16 per W value × 3 values). Total = 52 ERROR cells, 12 green cells = 64 total cells.
- No Julia run was performed (docs pass only).

**Files changed:**
- `BENCHMARKS.md` (+65 lines): new Pareto subsection + critical-path list update.
- `docs/paper_outline_T5.md` (NEW, ~110 lines): §T5 paper outline.
- `README.md` (~+20 lines, ~5 edited): memory strategy table row, two feature bullets, T5 status update.
- `worklog/071_*.md` (this entry, +~55 lines).

**Follow-up beads referenced (not filed here):**
- Bennett-8o70 (wide-W persistent callees) — already open.
- Bennett-7sb7 (HAMT optimize=false / assert-throw) — already open.
- Bennett-2xws (HAMT mod-32 key collision) — already open.
- Bennett-n88f (Rust corpus LLVM-version skew) — already open.

---

## Session log — 2026-05-20 — Bennett-ktt8 T5-P7a head-to-head Pareto benchmark

**Shipped:** `benchmark/bc_t5_head_to_head.jl` (520 LOC) — parameterized `impl × W × depth` persistent-map Pareto sweep. Each cell records gates/NOT/CNOT/Toffoli/Toffoli-depth/ancillae/wires/verify_reversibility/compile-seconds; cells that can't compile are fail-loud `ERROR` cells (CLAUDE.md §1) with the verbatim error, never silently skipped. Each green cell runs both `verify_reversibility` AND an oracle check (CLAUDE.md §4). Full 64-cell sweep ran → `benchmark/bc_t5_head_to_head_results.jsonl`.

**Why:** With all four `persistent_impl` arms wired (z2dj/6883/d746/qi6c), the cross-impl gate-count comparison is finally meaningful. Benchmark code only — not a 3+1 bead. Solo opus implementer; orchestrator scope-corrected the stale bead text and reviewed the measurement core.

**Result:** `:linear_scan` wins **every** (W,depth) cell — ~1150–1450 gates, essentially flat in depth (its branchless slot-preserve lowering compresses to ~constant). `:cf` 2nd (~9.6k–36k gates). `:okasaki` worst (~54k at depth 3 → ~3.5M at depth 128). **Recommended default = `:linear_scan`** — already the T5-P6 default, so no dispatcher tweak needed; confirms the 2026-04-20 `sweep_persistent_summary.md` conclusion.

**Gotchas / Lessons:**

1. **The bead text (2026-04-17) was doubly stale.** It assumed "3 hashcons states × W∈{8,16,32,64}". Reality: (a) only `hashcons=:none` is wired — `:naive`/`:feistel` throw; the hashcons axis collapses to 1 state. (b) Every `*_pmap_set/get` callee is hard-typed `Int8` (W=8) — see `linear_scan.jl:47` — so W∈{16,32,64} is structurally unreachable. The tractable sweep is `4 impls × W=8 × depth{3,8,32,128}`. The 48 W>8 cells are recorded as fail-loud ERROR cells; filed **Bennett-8o70** (wide-W persistent callees NYI). **Take-home:** benchmark beads filed far ahead of implementation accrete stale axes — scope-check against what's actually wired before running.
2. **HAMT is absent from the Pareto front — won't compile under `optimize=false`.** `hamt_pmap_set`'s `@assert` (hamt.jl:144) leaves a `j_print_to_string` call in the IR that `ir_extract.jl` rejects. Under `optimize=true` LLVM DCEs the assert (which is why `test_6883_hamt_dispatch.jl` passes). But `optimize=false` is the house benchmark/test methodology (CLAUDE.md §5). Filed **Bennett-7sb7**. HAMT's 4 cells are ERROR cells.
3. **optimize regime changes the numbers ~2×.** okasaki 3-key demo: `optimize=true`=26386 gates (worklog/071 6883 entry) vs `optimize=false`=53682 (this benchmark). Both correct — not a regression. Any cross-impl comparison must hold the optimize flag fixed; this benchmark uses `optimize=false` throughout.

**Rejected alternatives:** an `optimize=true` companion sweep to pull HAMT into the table — rejected: it would change every other impl's numbers too (regime must be held fixed), and HAMT is ~20× worse than linear_scan and carries the Bennett-2xws collision bug, so it cannot be the recommended default regardless. The recommendation is robust without it.

**Next agent starts here:** **Bennett-2uas** (T5-P7b — append this Pareto table to BENCHMARKS.md, WORKLOG session-log entries, paper-outline §T5, README feature table). The `bc_t5_head_to_head_results.jsonl` artifact is the input. Also open: Bennett-7sb7 (HAMT optimize=false), Bennett-8o70 (wide-W callees), Bennett-2xws (HAMT mod-32 collisions).

---

## Session log — 2026-05-20 — Bennett-qi6c :cf persistent_impl dispatcher arm — ALL FOUR IMPLS WIRED

**Shipped:** `:cf` (Conchon-Filliâtre semi-persistent map) is now a wired `persistent_impl` arm — byte-template duplicate of d746/`:hamt` + 6883/`:okasaki`. With `:cf` landed, **all four `persistent_impl` candidates (`:linear_scan, :okasaki, :hamt, :cf`) are wired**; `_resolve_persistent_impl`'s unconditional NYI `else` branch is gone (the final `else` now handles `:cf`, guaranteed by the top-of-function symbol validation). `_CALLEES_PERSISTENT` 6-tuple → 8-tuple (`cf_pmap_set, cf_pmap_get`). New `test/test_6883_cf_dispatch.jl` (53/53). `test_kmuj_callee_groups.jl` n_grouped 101→103. `test_t5_p6_persistent_dispatch.jl` testset 6 **consolidated** — the impl-NYI probe rotation (z2dj→6883→d746→qi6c) is retired since no NYI impl symbol remains; replaced with a hashcons-NYI probe (`:naive`) + a defensive bogus-symbol probe (`persistent_impl=:nonsense`).

**Why:** Last of the three Bennett-6883 follow-ups (d746 + qi6c). Not a 3+1 bead — registration/dispatch layer only. Solo implementer (opus subagent).

**Gotchas / Lessons:**

1. **CF correctness verified before wiring.** `verify_pmap_correctness(CF_IMPL)=true` — the Bennett-n3z4/U21 reroot-key=0 regression has NOT reappeared (the bit-63 was-allocated flag in `cf_pmap_set`'s diff index is the fix; `cf_reroot` no longer infers allocation from `old_key==0`). Per the qi6c bead caveat this check ran first; only after it passed did wiring proceed.
2. **`cf_reroot` deliberately NOT registered as a callee.** `cf_semi_persistent.jl` is explicit that `cf_reroot` is an internal documentation/test helper, never a public entry point — `cf_pmap_get` does its own O(max_n) branchless Arr scan and never IRCalls `cf_reroot`. The Diff-chain unwind is handled by Bennett's reverse pass, not an explicit reroot IRCall. Registering it would be a dead no-op.
3. **CF is collision-free** (true insertion-order persistent map, Arr+Diff — no hash slot), so unlike d746/`:hamt` no distinct-keys rejection sampler is needed; plain `rand(Int8)` keys work. CF 3-key demo gate count `total=2880 / Toffoli=308` — ~9× cheaper than okasaki (26386) and hamt (26440); a strong T5-P7a Pareto candidate. Not pinned.

**Rejected alternatives:** none — wiring shape fully determined by the okasaki/hamt arms.

**Next agent starts here:** the persistent_impl dispatch surface is complete (4/4 impls). Natural next pickup: **Bennett-ktt8** (T5-P7a head-to-head Pareto benchmark — can now compare all four impls; CF's 9×-cheaper gate count is a headline result). Open caveat for that bench: **Bennett-2xws** (HAMT mis-stores keys colliding mod 32 — HAMT head-to-head must restrict to collision-free key sets). Remaining NYI surface is purely the orthogonal `hashcons` layer (`:naive`/`:feistel`, tracked by Bennett-z2dj follow-ups).

---

## Session log — 2026-05-20 — Bennett-d746 :hamt persistent_impl dispatcher arm (okasaki template)

**Shipped:** `:hamt` is now a wired `persistent_impl` arm — byte-template duplicate of Bennett-6883's `:okasaki` wiring. `src/persistent/persistent.jl` gains `include("research/popcount.jl")` THEN `include("research/hamt.jl")` (ordering load-bearing — hamt's `_hamt_compressed_idx`/`hamt_pmap_get` call `soft_popcount32` from popcount.jl) + `HamtState, HAMT_IMPL, hamt_pmap_new/set/get` on the `Persistent` export list. `src/callees.jl` `_CALLEES_PERSISTENT` 4-tuple → 6-tuple (`hamt_pmap_set, hamt_pmap_get`; `hamt_pmap_new` NOT registered — all-zero state via WireAllocator zero invariant). `src/lowering/memory.jl` `_resolve_persistent_impl` gains `:hamt + hashcons=:none` arm. New `test/test_6883_hamt_dispatch.jl` (51/51) wired into runtests.jl. `test_kmuj_callee_groups.jl` n_grouped 99→101. `test_t5_p6_persistent_dispatch.jl` testset 6 NYI probe rotated `:hamt`→`:cf`.

**Why:** Bennett-6883 (2026-05-18) wired `:okasaki` and nailed the template; d746 + qi6c are its byte-template siblings. Not a 3+1 bead — registration/dispatch layer only, no core-file change. Solo implementer (opus subagent).

**Gotchas / Lessons:**

1. **HAMT silently mis-stores keys colliding mod 32.** `src/persistent/research/hamt.jl` is a single-level BitmapIndexedNode: slot = low 5 bits of the key. Two keys congruent mod 32 collide → latest-write-wins, NO collision node. The byte-template test FAILED 50/51 on the random sweep until a `_d746_distinct_hamt_keys()` rejection-sampler was added. `verify_pmap_correctness(HAMT_IMPL)` passes only because it probes keys 0..7 (distinct slots). linear_scan + okasaki are collision-free by construction. **Filed `Bennett-2xws` (P3 bug)** — a real correctness caveat for the T5-P7a Pareto bench (Bennett-ktt8): HAMT head-to-head must restrict to collision-free key sets or hamt.jl needs collision-node support.
2. HAMT 3-key demo gate count `total=26440 / Toffoli=6122` — comparable total to okasaki (26386) but ~1.6× more Toffolis; the `soft_popcount32` compressed-index path is Toffoli-heavy. Not pinned (per 6883 gotcha 4 — gate-count delta across impls is a Pareto axis, not a regression number).

**Rejected alternatives:** none — wiring shape fully determined by the 6883 `:okasaki` arm.

**Next agent starts here:** Bennett-qi6c (`:cf` arm — last NYI impl; verify `verify_pmap_correctness(CF_IMPL)` first per the Bennett-n3z4/U21 reroot-key=0 caveat). After qi6c, testset 6's impl probe can be consolidated to hashcons-only + a bogus-symbol validation probe (per 6883 gotcha 2).

---

## Session log — 2026-05-18 — Bennett-6883 :okasaki persistent_impl dispatcher arm (linear_scan template)

**Shipped:** `:okasaki` is now a wired `persistent_impl` arm. (a) `src/persistent/persistent.jl` gains `include("research/okasaki_rbt.jl")` (loaded unconditionally — the file still lives under research/ for blame continuity but is no longer research-tier once it's reachable from a public kwarg) and adds `OkasakiState`, `OKASAKI_IMPL`, `okasaki_pmap_new`, `okasaki_pmap_set`, `okasaki_pmap_get` to the `Persistent` module's `export` list. (b) `src/callees.jl` `_CALLEES_PERSISTENT` extended from 2-tuple → 4-tuple by appending `okasaki_pmap_set, okasaki_pmap_get`; `okasaki_pmap_new` deliberately NOT registered (same reason as `linear_scan_pmap_new`: all-zero output reached via WireAllocator's zero invariant per z2dj consensus §3+§4). (c) `src/lowering/memory.jl` `_resolve_persistent_impl` gains an `:okasaki + hashcons=:none` arm returning `Bennett.OKASAKI_IMPL`; mirrors the `:linear_scan` arm verbatim (only difference: the impl constant). The `else` branch's "NYI" error message updated to reflect that two impls now ship; the top-level "supported:" string also updated. (d) New test file `test/test_6883_okasaki_dispatch.jl` mirrors `test_t5_p6_persistent_dispatch.jl` testset 2 (3-key roundtrip): pure-Julia `verify_pmap_correctness(OKASAKI_IMPL)` + oracle-vs-direct + reversible-compile with `verify_reversibility` + concrete corner cases (all-zeros / HIT / MISS) + 10-trial random sweep + `@info` gate-count print (NOT pinned — see gotcha 4). Wired into `test/runtests.jl` directly after `test_t5_p6_persistent_dispatch.jl`. (e) `test/test_kmuj_callee_groups.jl` count assertions bumped: `_CALLEES_PERSISTENT` 2 → 4, total `n_grouped` 97 → 99. (f) `test/test_t5_p6_persistent_dispatch.jl` testset 6 ("NYI persistent_impl ... throw ArgumentError") updated to probe `:hamt` instead of `:okasaki` (the latter no longer throws). (g) `src/Bennett.jl` `CompileOptions` docstring for `persistent_impl` refreshed to note `:linear_scan + :okasaki` are wired.

**Why:** Bennett-z2dj wired the `:persistent_tree` alloca dispatcher with `:linear_scan` as the only impl. Bennett-6883's original scope was all three NYI impls (`:okasaki`/`:hamt`/`:cf`); this session takes only `:okasaki`, nailing down the wiring template for the remaining two (Bennett-d746 hamt + Bennett-qi6c cf — both byte-template duplicates of this work). NOT a 3+1 bead: the wiring shape was fully determined by the existing `:linear_scan` arm; the only design decision was "load research/okasaki_rbt.jl unconditionally vs flag-gate" — orchestrator pre-approved unconditional, and that's the right call (a wired impl reachable from a public kwarg is no longer research-tier).

**Gotchas / Lessons:**

1. **Persistent submodule's `export` does NOT propagate through to `names(Bennett)`.** I worried that adding `OKASAKI_IMPL` etc. to the `Persistent` module's `export` list would trip `test_uoem_research_relocation.jl`'s assertion that `OKASAKI_IMPL ∉ names(Bennett)`. Empirically it doesn't: `using .Persistent` makes the symbols available at `Bennett` scope (so `Bennett.OKASAKI_IMPL` resolves), but `names(Bennett)` only enumerates symbols that `Bennett` itself `export`s explicitly. The `Bennett.jl` `export` line for the persistent surface (line 69) is hand-curated and still lists ONLY `LINEAR_SCAN_IMPL`. uoem 29/29 GREEN. **Take-home:** the uoem assertion is about *Bennett's* public API, not about every reachable name; submodule exports surface as `Bennett.<NAME>` only via qualified access. If a future bead wants `OKASAKI_IMPL` in the public API (e.g. so downstream packages can `using Bennett` and write bare `OKASAKI_IMPL`), it needs to add the explicit `export OKASAKI_IMPL, ...` at `src/Bennett.jl`'s top-level export block (line 69) AND update uoem to remove the assertion. Today's wiring is the conservative choice: the impl is reachable but not part of the public API contract.

2. **`test_t5_p6_persistent_dispatch.jl` testset 6 had an `@test_throws ArgumentError` on `:okasaki` that flipped from PASS → FAIL.** This isn't a bug — testset 6's contract is "NYI kwargs fail loud", and `:okasaki` was NYI when z2dj landed. The fix is to update the probe to a still-NYI value (I chose `:hamt`; next session, when `:hamt` lands too, the next agent should bump to `:cf` or — once all four impls are wired — drop the impl probe entirely and keep only the hashcons probe). **Take-home:** when wiring an impl through a known-NYI gate, grep tests for `@test_throws.*<the_new_impl>` and either re-target or delete those probes — a flipping `@test_throws` is the canonical signal that a NYI symbol graduated to wired. Filed mentally: when `:cf` is the only remaining NYI, the next agent should consolidate testset 6 into a hashcons-only probe + a defensive `@test_throws ArgumentError ... persistent_impl=:nonsense` symbol-validation probe.

3. **`okasaki_pmap_get` and `okasaki_pmap_set` are reachable as callees because they're TOP-LEVEL definitions in `Persistent` submodule, NOT because they're `export`ed.** `register_callee!(f)` in `src/Bennett.jl` looks up `nameof(f)` and stores `f` directly — the export list is irrelevant to callee resolution. What matters is that the symbols are reachable at `callees.jl`'s parse scope, which they are post-`include("persistent/persistent.jl")` + `using .Persistent` (line 58 + 63 of `Bennett.jl`). Verified by `Bennett._known_callees["okasaki_pmap_set"]` returning the right function. **Take-home:** the `export` line in `Persistent` is COSMETIC for the callee registration — useful for users who want to do `Bennett.okasaki_pmap_new()` directly, but not load-bearing for the dispatcher. If `:hamt` follow-up agents want to skip the `export` line to keep the public surface tight, they can — the callee registration will still work.

4. **Gate count for 3-key `:okasaki` demo is 65× larger than `:linear_scan` (26386 vs 404).** Toffoli count: 3730 vs 90 (41×). Not surprising given the depth: linear_scan does 4 branchless slot writes per `set` (each a single MUX) and 4 branchless slot reads per `get`; okasaki does 4 slot reads + 3 trace-path reads + 4 case-MUX writes per `set` (RBT balance has LL/LR/RL/RR case-MUX × 3 nodes × 4 cases) and 3-level lookup per `get`. The gate count is not pinned as a regression baseline (per the task spec: "gate counts will be different from linear_scan; not regression-anchored yet"). When the T5-P7a Pareto bead runs, this number becomes one data point in the head-to-head; pinning it as a regression baseline can wait until empirical Pareto data is in. **Take-home:** the `:linear_scan` gate count was 1.0× anchor when only one impl shipped; with two impls, the gate-count *delta* across impls becomes a Pareto axis, not a regression number. Don't pin it yet.

5. **No source change to `bennett_transform.jl`, `lower.jl`, `ir_extract.jl`, or any other core file.** All changes are at the registration / dispatch / impl-loading layer. The lowering pipeline is impl-agnostic: it calls `_resolve_persistent_impl` once at `validate_persistent_config` (front-load of kwarg validation per z2dj Step 9), and threads the resolved `impl` value through to `_lower_store_via_persistent!` / `_lower_load_via_persistent!`. Bennett's reverse pass works the same way regardless of which impl's `pmap_set` was IRCall'd. **Take-home:** the `:hamt` and `:cf` follow-ups should not touch core lowering; if either of them surfaces a core-lowering issue, that's a NEW bead (impl-specific IR shape), not a 6883-followup concern.

6. **dolt auto-push fails on every `bd create` / `bd close` (HTTPS auth)** — same as worklog/071 §5 (smjd) and worklog/070 §3 (z2dj). Bennett-d746 (hamt) and Bennett-qi6c (cf) created locally + Bennett-6883 closed locally; the dolt-cache files at `.beads/embeddeddolt/beads/.dolt/...` show up as modified binary files in `git status`. Per CLAUDE.md "Dolt-cache commit hygiene" they go in the same commit as the source change. Verified by `git status` showing exactly the source files + the dolt-cache files (no orphans).

**Rejected alternatives:**

- **Flag-gating the `include("research/okasaki_rbt.jl")` behind `BENNETT_RESEARCH_TESTS=1` (or a similar build flag).** Orchestrator pre-approved unconditional and that's correct: once the impl is reachable from a public kwarg (`persistent_impl=:okasaki`), it's no longer research-tier by definition. Flag-gating would force every user who wants `:okasaki` to also set an env var, which is a footgun. The research/ subdir convention from Bennett-uoem / U54 was "preserved-but-deprecated"; the file location is preserved (for blame / history) but the deprecation no longer applies. Tests like `test_persistent_okasaki.jl` that exercise the IMPL's exhaustive pure-Julia conformance (research-tier coverage) stay gated behind `BENNETT_RESEARCH_TESTS=1` — those are about impl correctness, not about whether the impl is wired.
- **Registering `okasaki_pmap_new` as a callee.** Rejected per consensus §3+§4 (same reason as `linear_scan_pmap_new`): `pmap_new` returns the all-zero state, which is reached for free via WireAllocator's zero invariant when `lower_alloca_dynamic_n!` allocates the slab wires. There's no IRCall for it — the wires arrive zero by construction. Registering it would be a no-op (no LLVM callsite would ever resolve to it).
- **Adding `OKASAKI_IMPL` to `src/Bennett.jl`'s top-level `export` list.** Rejected to preserve the uoem invariant. The `Persistent` submodule exports them (so `using Bennett.Persistent` works) and `Bennett.OKASAKI_IMPL` works via qualified access. If a future user actually needs bare `OKASAKI_IMPL` after `using Bennett`, that's a public-API expansion bead, not a 6883 concern.
- **A 3+1 design review for the wiring choice.** The wiring template was nailed down by z2dj's `:linear_scan` arm; there was no design space to explore. Per the task spec: "This is NOT a 3+1 bead." Implementer ran solo per the spec.

**Verification:**

| File | Result |
|---|---|
| `test/test_6883_okasaki_dispatch.jl` (NEW) | **51/51 pass** |
| `test/test_t5_p6_persistent_dispatch.jl` | **323/323 pass** (testset 6 probe switched from `:okasaki` → `:hamt`) |
| `test/test_persistent_interface.jl` | **88/88 pass** (linear_scan gate-count anchor total=404 / Toffoli=90 UNCHANGED) |
| `test/test_kmuj_callee_groups.jl` | **333/333 pass** (was 327; +6 = 4 disjointness / 1 in_known_callees / 1 count assertions for okasaki_pmap_set + okasaki_pmap_get; group-size assertion for `_CALLEES_PERSISTENT` 2 → 4; total `n_grouped` 97 → 99) |
| `test/test_gate_count_regression.jl` | **39/39 pass** |
| `test/test_uoem_research_relocation.jl` | **29/29 pass** (OKASAKI_IMPL still NOT in `names(Bennett)` per gotcha 1) |

Okasaki 3-key demo gate counts (raw measurement, NOT pinned):
- `total = 26386 / NOT = 3148 / CNOT = 19508 / Toffoli = 3730`
- vs linear_scan 3-key demo: `total = 404 / NOT = 8 / CNOT = 306 / Toffoli = 90`
- Ratio ~65× total, ~41× Toffoli — expected (deeper branchless RBT).

**Files changed:**
- `src/persistent/persistent.jl` (+13, -2): `include("research/okasaki_rbt.jl")` + bump `export` line with `OkasakiState, OKASAKI_IMPL, okasaki_pmap_*` + docstring note about 2026-05-18 graduation out of research-only.
- `src/callees.jl` (+3, -2): `_CALLEES_PERSISTENT` 2-tuple → 4-tuple; comment refreshed.
- `src/lowering/memory.jl` (+12, -3): `_resolve_persistent_impl` gains `:okasaki + hashcons=:none` arm; "supported:" string updated; `else` branch's NYI message points at d746/qi6c not z2dj.
- `src/Bennett.jl` (+1, -1): `CompileOptions` docstring for `persistent_impl` says "linear_scan + okasaki wired" not "only linear_scan".
- `test/test_6883_okasaki_dispatch.jl` (NEW, ~110 LOC): three testsets — pure-Julia conformance + demo-oracle parity + reversible-compile + gate-count `@info`.
- `test/runtests.jl` (+4): wired `test_6883_okasaki_dispatch.jl` after `test_t5_p6_persistent_dispatch.jl`.
- `test/test_kmuj_callee_groups.jl` (+3, -3): `n_grouped` 97 → 99; `_CALLEES_PERSISTENT` group-size 2 → 4; in-comment explanation.
- `test/test_t5_p6_persistent_dispatch.jl` (+11, -4): testset 6 probe switched from `:okasaki` to `:hamt` with comment explaining the rotation pattern.
- `worklog/071_2026-05-18_smjd_persistent_diamond.md` (this entry).

**Follow-up beads filed:**
- **Bennett-d746** (P3, OPEN) — wire :hamt persistent_impl arm. Byte-template duplicate of this work; description includes the explicit "do A then B then C" checklist + note about HAMT's popcount.jl dependency + the uoem invariant.
- **Bennett-qi6c** (P3, OPEN) — wire :cf persistent_impl arm. Byte-template duplicate; description carries a CAVEAT about Bennett-n3z4 / U21 (CF reroot-key=0 regression — run `verify_pmap_correctness(CF_IMPL)` first before wiring).
- (Also closed: **Bennett-6883** itself — see close-reason for the full peer-regression table.)

**Next agent starts here:** pick one of (a) **Bennett-d746** (the natural 6883 sibling — wire `:hamt`; first verify `verify_pmap_correctness(HAMT_IMPL)` passes, then follow the 5-step recipe above); (b) **Bennett-qi6c** (`:cf` arm; first check the n3z4 regression hasn't reappeared); (c) **Bennett-ktt8** / T5-P7a (head-to-head Pareto benchmark — now that two impls ship, the cross-impl gate-count comparison the worklog stops short of is the natural next step); (d) pivot to the non-T5 in-progress beads as in worklog/071's 25dm next-agent list (cc0.5 / tzrs / vdlg / 8su4).

---

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
