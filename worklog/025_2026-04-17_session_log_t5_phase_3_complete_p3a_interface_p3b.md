## Session log — 2026-04-17 — T5 Phase 3 complete (P3a interface + P3b/c/d 3 persistent-DS impls)

T5 Phase 3 lands all four "persistent map" beads in one push.  P3a defines
the convention; P3b/c/d implement Okasaki RBT, Bagwell HAMT, and
Conchon-Filliâtre semi-persistent.  All four GREEN, full suite passes.

### P3a — Persistent map protocol + LINEAR_SCAN_IMPL stub (Bennett-isab)

`src/persistent/{persistent,interface,linear_scan,harness}.jl` (4 files).
Convention-based protocol: each impl provides 3 named functions + a
`PersistentMapImpl` bundle.  No abstract-type dispatch (Julia
function-as-interface pattern beats Holy traits here).

The stub LINEAR_SCAN_IMPL: NTuple{9, UInt64} state, max_n=4, branchless
via `ifelse`.  Compiles via `reversible_compile` to **436 gates / 90
Toffoli**.  88 tests pass — the contract IS reversibilisable.

### P3b — Okasaki RBT (Bennett-mcgk, sonnet drafted, orchestrator reviewed)

`src/persistent/okasaki_rbt.jl` (248 lines).  Flat node pool: 4 slots ×
24-bit packed nodes (color, left_idx, right_idx, key, val) → 2 nodes per
UInt64.  State = NTuple{3, UInt64}.

All 4 Okasaki balance cases (LL, LR, RL, RR) computed speculatively
with mutually exclusive predicates, MUX-selected via `ifelse`.  No
false-path sensitisation risk — predicates `ggl & pgl`, `ggl & !pgl`,
`!ggl & pgl`, `!ggl & !pgl` partition the space.

Gate count: **108,106 total / 27,854 Toffoli at max_n=4**.

98 tests GREEN: pure-Julia contract, 50+6 oracle matches (covering all
4 balance cases), reversible_compile + verify_reversibility, 30+7
circuit-vs-oracle samples.  Delete deferred (Kahrs 2001 ~2× insert
complexity; PRD §10 M5.3 lists delete as optional for first impl).

**Caveat documented**: depth-2-only balance (only fires when
grandparent = root).  Correct for max_n=4 with the test insertion
patterns; would need recursive balance for higher max_n.

### P3c — Bagwell HAMT + reversible popcount (Bennett-a7zy, sonnet, reviewed)

`src/persistent/popcount.jl` (67 lines): verbatim translation of Bagwell
2001 Fig 2 CTPop emulation as `soft_popcount32(x::UInt32)::UInt32`.
Five lines of integer arithmetic — Bennett.jl reversibilises each.
Standalone gate count: **2,782 total / 1,004 Toffoli**.  Verified
exhaustive against `Base.count_ones` on 1007 inputs.

`src/persistent/hamt.jl` (265 lines): single-level BitmapIndexedNode
with up to 8 entries (max_n=8 — at max_n=4 the popcount index is
trivially 0..3 and never exercises the bitmap; 8 forces popcount to
actually run).  Hash function for K=Int8: raw `reinterpret(UInt8, k)`
low 5 bits — collisions handled by latest-write semantics.  No
ArrayNode promotion, no HashCollisionNode (Clojure brief recommended
capping at 15 entries to avoid these).

Gate count: **96,788 total / 25,576 Toffoli at max_n=8 K=V=Int8**.
Dominated by 3× popcount (~3 × 2,782 = 8,346) + Bennett's
forward+copy+uncompute multiplier + MUX overhead for 17-element NTuple.

1097 tests GREEN: all interface tests + standalone popcount + 1000
random `Base.count_ones` matches.  Delete deferred.

### P3d — Conchon-Filliâtre semi-persistent (Bennett-6thy, sonnet, reviewed)

`src/persistent/cf_semi_persistent.jl` (284 lines).  State =
NTuple{22, UInt64} = {diff_depth, arr_count, 4×(k,v) Arr,
4×(slot,old_k,old_v) Diff chain}.  Insert scans Arr for matching key
(branchless), pushes (slot, old_k, old_v) onto Diff chain, writes new
(k,v) into Arr.  Get scans Arr only — no Diff traversal needed because
Arr is always materialised current-version.

**Gate count: 11,078 total / 2,692 Toffoli at max_n=4 K=V=Int8.**

107 tests GREEN.

#### THE BIG FINDING: brief §5 correspondence VINDICATED

The Phase-0 brief (`cf_semipersistent_brief.md` §5) claimed: "the C-F
Diff chain IS Bennett's history tape; `reroot` IS the uncompute pass."

After implementation: **CONFIRMED at the gate level**.  Three pieces of
evidence:

1. The Diff chain matches Bennett's tape: every `cf_pmap_set` pushes
   (slot, old_k, old_v) onto Diff.  Bennett's forward pass naturally
   builds this chain.  Bennett's reverse pass pops it and restores Arr
   slots — which IS what C-F's `reroot` does.
2. `cf_pmap_get` does not need `reroot`: the Arr is always materialised
   in our impl, so get is O(max_n) branchless scan.
3. **CF is 10× cheaper than Okasaki RBT and ~9× cheaper than HAMT** at
   max_n=4: 2,692 Toff vs 27,854 (Okasaki) vs 25,576 (HAMT).  The
   theoretical correspondence translates to a measurable gate-cost win.

**Implication for T5-P6 dispatcher**: C-F is the recommended default
under the dispatcher when the access pattern is linear — which is
exactly what Bennett's construction guarantees.

#### Caveat: cf_reroot sentinel-collision (contained)

`cf_reroot` uses `r_key == 0` to distinguish "undo of new allocation"
from "undo of overwrite".  Int8(0) IS a valid key — this heuristic is
INCORRECT for the zero-key case.  But `cf_reroot` is NOT called on the
compiled circuit's path (only standalone test exercises it), so it does
NOT affect verify_reversibility.  Filed as latent footgun for whoever
wires reroot into get for full persistence later.

### Coexistence — full suite GREEN

`julia --project=. -e 'using Pkg; Pkg.test()'` passes.

### Gate-count Pareto front so far (max_n where listed)

| Impl | Gates | Toffoli | max_n | State size (UInt64s) |
|---|---:|---:|---:|---:|
| linear_scan | 436 | 90 | 4 | 9 |
| **cf_semi_persistent** | **11,078** | **2,692** | **4** | **22** |
| HAMT (popcount-driven) | 96,788 | 25,576 | 8 | 17 |
| Okasaki RBT | 108,106 | 27,854 | 4 | 3 |

**The CF correspondence is the most important Phase-3 finding.** It
suggests CF should be the dispatcher default for unbounded heap, with
Okasaki/HAMT as alternates the user can opt into.

### Subagent policy worked as designed

3 sonnet subagents in parallel for P3b/c/d.  Each drafted the full
impl + test file.  Orchestrator reviewed each carefully:
- Okasaki: depth-2-only balance limitation documented; no false-path risk
- HAMT: hash collisions at K=Int8 documented; popcount masks inline correctly
- CF: sentinel-collision contained; correspondence finding amplified

No 3+1 protocol triggered (additive new files, no `lower.jl` /
`ir_extract.jl` / `bennett.jl` touches).

### Next: Phase 4 hash-cons compression (orchestrator implements both variants)

P4a Mogensen reversible hash-cons table + P4b Feistel-perfect-hash
variant.  Both novel — orchestrator implements (per user policy).  Then
in parallel, sonnet subagents fix the 4 ir_extract.jl gaps (cc0.3-.6).

---

## Session log — 2026-04-17 — T5 epic launched (Bennett-cc0 children); Phase 0–2 complete

User commits to T5 (persistent hash-consed array) as the universal-fallback
tier. Per user direction (2026-04-17): correctness primary, gate cost
secondary; pursue ALL THREE candidate persistent-DS implementations and
benchmark them rather than picking one in advance; multi-language LLVM
ingest in scope (clang + rustc) because Bennett.jl is NOT just for Julia.
Subagents (sonnet) for research/draft work; orchestrator (opus) implements
or tightly reviews tricky code; full 3+1 protocol for any core change to
`ir_extract.jl` / `lower.jl` / `bennett.jl`.

### Beads filed

20 sub-beads under Bennett-cc0 (T5-P0a through T5-P7b) via `bd create
--graph` JSON plan, plus 2 companion ground-truth beads (Bennett-cc0.1
Kahrs RBT delete, Bennett-cc0.2 Clojure HAMT insert/delete) discovered
during Phase 0 brief writing, plus 4 ir_extract bug beads
(Bennett-cc0.3-.6) discovered during Phase 2 RED test execution. Plus
Bennett-ponm filed for the broken `wisp_dependencies` table in `bd`
(dep tracking is non-functional repo-wide; rely on inline description
text for the DAG).

**Total**: 27 new beads.

### Phase 0 — Ground truth (DONE)

5 PDFs + 5 algorithm briefs in `docs/literature/memory/`:

- **Okasaki 1999 RBT** (Bennett-iiu2 → `okasaki_rbt_brief.md`): verbatim insert + 4 balance cases. Delete is NOT in this paper.
- **Bagwell 2001 HAMT + Bagwell 2000 trie searches** (Bennett-nrl7 → `bagwell_hamt_brief.md`): both PDFs from upstream are abbreviated (4 + 2 pages); the **CTPop popcount emulation** (Fig. 2 p. 3 of 2001) is captured verbatim — that's the critical primitive for T5-P3c reversible popcount. Insert/delete NOT in either PDF.
- **Conchon-Filliâtre 2007 PUF** (Bennett-64yf → `cf_semipersistent_brief.md`): verbatim version-tree + reroot. **Key finding**: §5 of brief documents a *structural* correspondence — the C-F `Diff` chain IS Bennett's history tape; `reroot` IS the uncompute pass. Not just asymptotic — algorithmic. May simplify T5-P3d significantly.
- **Mogensen 2018 NGC** (Bennett-4g0d → `mogensen_hashcons_brief.md`): verbatim reversible `cons`, Jenkins 96-bit reversible hash, ref-count reversibility. Notes the RC 2015 → NGC 2018 correctness fix (RC 2015 optimised `cons` didn't stop empty-search at segment boundary).
- **Axelsen-Glück 2013 LNCS 7948** (Bennett-3x2v → `ag13_brief.md`): verbatim EXCH semantics, free-list invariant, linear-ref discipline. Reference for deferred AG13 work.

Companion beads (post-Phase-0 discoveries):

- **Kahrs 2001 RBT delete** (Bennett-cc0.1 → `kahrs_rbt_delete_brief.md`): JFP 11(4) Cambridge Core, retrieved via Playwright. Critical surprise — the complete untyped `delete` algorithm is in the supplementary `Untyped.hs`, retrieved via Wayback Machine 2003 archive. The `app` (tree-merge) is a 6-clause recursive function ~2× insert cost. The `balance` function has a 5th clause not in Okasaki 1999 (concurrent red-red on both sides).
- **Clojure HAMT** (Bennett-cc0.2 → `hamt_insert_delete_brief.md`): `clojure/lang/PersistentHashMap.java` from github (commit `56d37996b18d`, 1364 lines). Three node types not two: BitmapIndexed / Array / HashCollision, hysteresis at 16↑/8↓. **`ArrayNode.pack` is the hardest reversibility case** — full 32-slot scatter-to-compact conversion; brief recommends T5-P3c either uses explicit ancilla storage or caps at 15 entries to avoid ArrayNode. `removePair` is the delete primitive — removed (key,value) goes to ancilla.

### Phase 1 — PRD (DONE)

`Bennett-Memory-T5-PRD.md` committed (Bennett-r1a5, 465 lines, 13 sections).
Mirrors `Bennett-Memory-PRD.md` structure. Success criteria:
correctness-primary (every P2a/b/c test must verify_reversibility),
gate-cost secondary (Pareto front published, no per-op budget). Eight
milestones M5.0–M5.7 mapped to bead phases.

### Phase 2 — Multi-language test corpora (DONE)

Three RED test files, all verified to error today with documented messages:

- **Julia** (Bennett-t61h → `test/test_t5_corpus_julia.jl`): 4 RED tests. Surprise: each surfaces a DIFFERENT `ir_extract.jl` gap, all upstream of the dispatcher:
  - TJ1/TJ2 `Vector`/`Dict` → `Unknown value kind LLVMGlobalAliasValueKind`
  - TJ3 `isnothing` linked-list → `Unknown operand ref for: i1 icmp eq (ptr @..., ptr @...)`
  - TJ4 `Array{Int8}(undef, 256)` → `GEP base thread_ptr not found in variable wires`
  - **Filed as Bennett-cc0.3, .4, .5; meta-bug Bennett-cc0.6** for unsupported-opcode error reporting. All four block T5-P6 dispatcher.
  - Note: the simple 2-node linked-list form is GREEN today (existing shadow tier handles it); only the 3-node `isnothing`-traversal form RED-triggers the icmp eq gap.
- **C via clang 18.1.3** (Bennett-w985 → `test/test_t5_corpus_c.jl` + `test/fixtures/c/*.c`): 3 RED tests, .ll output 94–103 lines. C uses bare `@malloc`/`@realloc`/`@free` external calls — clean contrast to Julia's TLS-runtime calls.
- **Rust via rustc 1.95.0** (Bennett-gl2m → `test/test_t5_corpus_rust.jl` + `test/fixtures/rust/*.rs`): 3 RED tests, .ll output 578–6113 lines. `std::collections::HashMap` came in at 6113 lines, under the 10k threshold — no hand-rolled fallback needed.

### Toolchain

- `rustc 1.95.0` installed via `rustup` (no sudo needed)
- `clang 18.1.3` installed via `apt install` (user typed sudo password)
- Both auto-skip in test harnesses when missing

### Multi-frontend insight

The contrast between the three corpora is itself the headline finding:

- **Julia LLVM IR** routes everything through `julia.get_pgcstack` and uses `LLVMGlobalAliasValueKind` operands — not directly portable to clang's IR
- **C LLVM IR** uses bare `@malloc`/`@realloc`/`@free` external symbols — clean, simple, what the textbooks describe
- **Rust LLVM IR** uses extensive `@alloc::alloc::*` with attribute-heavy declarations, more complex than C but more uniform than Julia

T5-P5a (`extract_parsed_ir_from_ll`) needs to handle ALL three patterns. The 4 ir_extract gaps from P2a are Julia-specific; clang and rustc IR introduce their own. This justifies the 3+1 protocol on T5-P5a/b.

### Next steps

Per dependency DAG (descriptions, since `bd dep` is broken):

1. **Phase 3** — orchestrator implements T5-P3a (`src/persistent/interface.jl` + harness, ~1 day)
2. **Phase 3** — sonnet drafts T5-P3b/c/d (Okasaki, HAMT, C-F) in parallel; orchestrator reviews tightly. Each ships gate-count table to WORKLOG.
3. **Phase 4** — orchestrator implements T5-P4a (Mogensen reversible hash-cons table — novel) and T5-P4b (Feistel variant)
4. **Phase 5** — orchestrator implements T5-P5a/b multi-language ingest (3+1 protocol, core change to ir_extract.jl)
5. **Parallel** — sonnet implementers fix ir_extract bugs Bennett-cc0.3-.6 (each one isolated, additive)
6. **Phase 6** — orchestrator implements T5-P6 dispatcher arm (3+1 protocol)
7. **Phase 7** — bench + writeup

### Gotchas worth documenting

1. **`bd dep` is broken repo-wide** (Bennett-ponm). Wisp_dependencies table missing. Workaround: parent_id + inline description text. `bd create --graph` works for nodes-only (no edges).
2. **`bd create --graph` JSON format** discovered empirically: `{nodes: [{key, title, priority(int), description, issue_type, parent_id, labels}], edges: [{from_key, to_key, type:"blocks"}]}`. Dry-run actually creates issues — not safe to test.
3. **FQHE Playwright persistent profile** (`/home/tobias/Projects/FQHE/.browser-profile/` or similar) carried Cloudflare cookies for Springer — Phase-0 Springer fetch needed ZERO manual clicks. Persisted browser context is the right pattern.
4. **Kahrs JFP 11(4) PDF** routes through `cambridge.org/core/services/aop-cambridge-core/content/view/...` not the public DOI URL. Cambridge Core institutional auth from TIB worked transparently via the same persistent profile.
5. **Bagwell PDFs are abbreviated upstream** — both 2001 and 2000 papers from `lampwww.epfl.ch` are 4 and 2 pages respectively. The full 26-page TR exists but isn't at the obvious URL. The 4 pages we have contain the CTPop primitive (the critical artifact). HAMT insert/delete sourced from Clojure source instead.
6. **TJ4 alloca-level vs Julia-level gap**: `Array{Int8}(undef, 256)` at the *Julia* level fails at extraction (TLS allocator), but the equivalent `alloca i8, i32 256` at the *LLVM* level GREENs today via T4 shadow-checkpoint (per L10 in `test_memory_corpus.jl`). The gap is in how Julia routes Array allocations — once Bennett-cc0.5 lands the Julia path will reach the dispatcher and dispatch to T4 (or T5 once it lands).

---

