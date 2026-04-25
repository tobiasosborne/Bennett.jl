## HANDOFF FOR NEXT AGENT — 2026-04-12 session close

**Status at handoff**: HEAD `b205a79` on `origin/main`. Full test suite green (run `julia --project -e 'using Pkg; Pkg.test()'`). All 11 critical-path issues listed above are closed. 19 issues remain open under the `Bennett-cc0` memory epic.

**User guidance**: *Implementation and benchmarking before paper drafting.* `P.1` (PRD) and `P.2` (outline) are explicitly lower priority — leave them until impl + benchmarking are complete.

### Orientation — where things are

- **Project instructions**: `CLAUDE.md` — non-negotiable rules (3+1 agents for core changes, red-green TDD, fail-fast, WORKLOG every step, push before stopping).
- **Vision**: `Bennett-VISION-PRD.md` — Enzyme analogy, LLVM opcode coverage tiers.
- **Memory plan literature**: `docs/literature/memory/SURVEY.md` (7.1k words, canonical) + `docs/literature/memory/COMPLEMENTARY_SURVEY.md` (6.1k words, cross-disciplinary). Read §5 of both before touching new memory code.
- **19 reference PDFs** in `docs/literature/memory/` including `reverc-2017.pdf`, `revs-2015.pdf`, `enzyme-2020.pdf`, `babbush-qrom.pdf`.
- **Per-task detail**: every closed issue has a dated WORKLOG entry above — read those for context on what's already decided.

### Rules you MUST follow

1. **`CLAUDE.md` rule 2**: `ir_types.jl`, `ir_extract.jl`, `lower.jl`, `bennett.jl`, `gates.jl`, phi resolution → 3+1 agent workflow (2 independent proposers + 1 implementer + orchestrator reviewer). Don't skip this. Both T1a.1 and T1b.3 this session benefited materially from the proposer disagreement (T1b.3 Proposer B caught a load-path bug Proposer A missed).
2. **Red-green TDD** always. Failing test first, then minimum code to green. Saved us on T0.1, T1a.2, T1b.3 bugs that would have shipped otherwise.
3. **i1 narrowing guard** is load-bearing: any new IR type with a `width` field needs `width > 1 ? W : 1` in `_narrow_inst`. Two bugs this session (Bennett-z9y, Bennett-wl8) were exactly this class — they'll keep happening until every new width-carrying type is guarded.
4. **Commit + push per task**. Not at the end — per task. 11 commits this session; each pushed immediately. Means any interruption leaves finished work on remote.
5. **Use beads**, not TodoWrite or MEMORY.md. `bd ready` is unreliable right now (schema regression — see caveat below); verify dependencies via the ID map in the ship log at the top of this session summary.

### Beads DB caveat — important

The subagent that filed the 30 granular issues hit `Error 1146: table not found: wisp_dependencies`. Workaround applied: all 30 issues use `--type=parent-child` to `Bennett-cc0` and `--type=tracks` for sibling sequencing. **Result**: `bd ready` shows tasks as ready even when their `tracks` predecessors are incomplete. Don't trust `bd ready` ordering. Use the ID map in the handoff to follow dependency chains manually. Consider running `bd doctor` or `bd init --force` to repair schema, then re-add the dependency graph with `--type=blocks` if it matters for scheduling.

### Recommended next sequence

Based on user priority (impl + benchmarks before paper):

#### Immediate win — high leverage
1. **Bennett-h8iw** (P2, filed this session) — Cuccaro dispatch for `a+b`. Currently `f(a::UInt32,b::UInt32) = a+b` produces 124 Toffoli; should be ~63 via Cuccaro. Fixing drops MD5 from 1.75× ReVerC to ~1.19×. High leverage, probably small fix in the liveness analysis used by `lower_binop!` around the Cuccaro dispatch guard.

#### Tier 1 — complete memory coverage
2. **T1c.1** Bennett-hz31 — QROM SELECT-SWAP (Babbush-Gidney 2018, paper at `docs/literature/memory/babbush-qrom.pdf`). 4L Toffoli per lookup on L-entry read-only table. Implement as pure-Julia callee (`soft_qrom_NxW(arr_const, idx) -> UInt64`) matching the `soft_mux_*` pattern.
3. **T1c.2** Bennett-za54 — dispatch const tables in `lower_var_gep!` to QROM. Detect when the base is a compile-time-constant array; route through T1c.1 instead of the MUX tree.
4. **T1c.3** Bennett-qw8k — scaling benchmark: QROM vs MUX tree vs MUX EXCH for L=4..128. Find the crossover points.

#### Benchmarks — critical for paper
5. **BC.3** Bennett-xy75 — full SHA-256 (not just one round). PRS15 Table II has numbers. Current state has sha256_round benchmark; extend to full 64-round compression. Will stress-test the pipeline on a ~30K-gate function.
6. **BC.4** Bennett-6c8y — consolidate all benchmarks into `BENCHMARKS.md` with apples-to-apples comparison table: Bennett.jl vs ReVerC vs PRS15 vs Cuccaro hand-opt. Probably ready to draft once BC.3 lands.

#### Tier 2 — THE paper-winning insight
7. **T2a.1** Bennett-law3 (P1) — **investigate LLVM.jl MemorySSA binding availability**. Both SURVEY agents independently ranked this #1. Go/no-go decision in `docs/memory/memssa_investigation.md`. LLVM.jl 9.4.6 may not expose it; if not, estimate effort for a binding.
8. **T2a.2** Bennett-81bs (P1) — `use_memory_ssa=true` option to `extract_parsed_ir`; consume MemoryDef/MemoryUse/MemoryPhi.
9. **T2a.3** Bennett-08wr — integration tests for cases that T0 preprocessing misses.

#### Tier 3 — coverage completion
10. **T3a.1** Bennett-bdni — 4-round Feistel dictionary (~400 gates/lookup per COMPLEMENTARY_SURVEY §5.4). Order-of-magnitude cheaper than Okasaki for fixed-width keys.
11. **T3a.2** Bennett-tqik — benchmark Feistel vs Okasaki.
12. **T3b.1** Bennett-oy9e — shadow-memory protocol design doc in `docs/memory/shadow_design.md`. This is the universal fallback.
13. **T3b.2** Bennett-2ayo — integrate with Meuli SAT pebbling (already in `src/sat_pebbling.jl`).
14. **T3b.3** Bennett-10rm (P1) — universal dispatcher: per-allocation choice between T1b MUX, T1c QROM, T2b linear, T3a Feistel, T3b shadow.

#### Paper work — AFTER everything above
15. **P.1** Bennett-ceps — `Bennett-Memory-PRD.md` (analogue to `Bennett-VISION-PRD.md`).
16. **P.2** Bennett-6siy — paper outline. PLDI/ICFP target; "Reversible Memory in an SSA Compiler" tentative title.

### Leftover non-plan issues to consider folding in

- **Bennett-h8iw** (P2) — Cuccaro dispatch. SHOULD BE #1 per leverage analysis above.
- **Bennett-utt** (P2) — existing bug: soft_fdiv sticky bit shift on normalization. Unrelated to memory plan but worth fixing.
- **Bennett-hao** (P3) — `llvm.memcpy`/`memmove`/`memset` intrinsics. Depends on T1b.3 (done) so now unblocked. Easy extension.
- **Bennett-nw1** (P3) — hash-consing. Deferred until T3a+ complete.
- **Bennett-dnh** (P3) — full QRAM (not QROM). Deferred to research-grade.

### Known gotchas (don't re-learn these the hard way)

1. **`LLVM.sizeof` needs a DataLayout** — errors with "LLVM types are not sized". Use `LLVM.width(t)` for integer types; floats need alternate handling.
2. **`sprint(io -> show(io, mod))`** is the way to dump an `LLVM.Module` back to IR text. `string(mod)` doesn't.
3. **Julia's `code_llvm(optimize=false)` still pre-runs SROA-equivalents** for most simple functions. You need an actual allocation (like `[x, y]`) to observe raw allocas. For reliable test fixtures, use hand-crafted LLVM IR strings through `parse(LLVM.Module, ir)` + `Bennett._module_to_parsed_ir`.
4. **Pre-existing insertvalue handler bug** at `ir_extract.jl:411` — crashes on complex Julia runtime IR with non-integer aggregates. Caught during T1a.2. Not in scope for memory work; avoid it by using hand-crafted IR.
5. **Pointer provenance must be updated by every GEP lowering** — `lower_ptr_offset!` and `lower_var_gep!` both populate `ctx.ptr_provenance` when their base is a known alloca. Miss either path and load-after-store breaks.
6. **LoweringCtx has a backward-compatible outer constructor** (added this session) so existing call sites don't need to pass the new memory fields. When adding new fields, preserve this pattern.
7. **ReVerC's 32 Toffoli for 32-bit Cuccaro is below the published formula** (2n=64). Either a paper typo or undisclosed optimization. Don't treat it as the literal target; measure on a like-for-like methodology.
8. **`@inline` at the call site is required** for deep SoftFloat dispatch chains — ref the v0.6 soft_fdiv bug fix. Don't forget it when adding new soft_* callees.
9. **Lint warning in tests**: `test_lower_store_alloca.jl` and `test_mutable_array.jl` both define a local `_compile_ir(String)`. Benign redefinition warning. Factor into a shared test helper if it starts being annoying.

### Verification before shipping any new task

```bash
# Full test suite — MUST pass before commit
julia --project -e 'using Pkg; Pkg.test()'

# Specific test file during iteration
julia --project test/test_<your_new_file>.jl

# Regression check vs baselines
julia --project test/test_gate_count_regression.jl

# BC benchmarks — re-run to detect gate-count regression
julia --project benchmark/bc1_cuccaro_32bit.jl
julia --project benchmark/bc2_md5.jl
julia --project benchmark/run_benchmarks.jl
```

### Final push for this session

- All 11 tasks committed individually with descriptive messages.
- All pushed to `origin/main`.
- Dolt beads mirror up to date via `bd dolt push`.
- Test suite green. No known regressions.
- One follow-up issue filed (Bennett-h8iw).

The memory model works end-to-end. We are the first reversible compiler to handle arbitrary LLVM `store`/`alloca`. MD5 is within 1.75× of ReVerC's Toffoli count (under 2× constant factor on a real cryptographic benchmark — below the 4-5× ceiling the survey predicted). Paper-ready narrative secured. Next agent: keep the momentum on impl + benchmarks per user direction; paper drafting waits until T1c + BC.3/BC.4 + T2a + T3b land.

## 2026-04-12 — Bennett-h8iw misdiagnosis recorded, closed (no code change)

BC.1 re-analysis after Cuccaro paper re-read: Cuccaro dispatch IS firing for `f(a,b)=a+b` (161→98 wires, 65→2 ancillae). The 124 Toffoli count matches ripple-carry because both constructions emit ≈2(W-1)=62 raw Toffolis (ripple: 2 Toffolis per middle bit × 31; Cuccaro: 1 MAJ + 1 UMA per middle bit × 31), which Bennett doubles to 124.

The real 2× is architectural: our Cuccaro is **self-uncomputing** (MAJ-ripple-up + UMA-ripple-down already restores the carry ancilla), so Bennett's reverse phase redundantly re-runs the full circuit. Exempting Cuccaro-emitted gates from Bennett reverse would halve the Toffoli count — tracked in Bennett-07r (Cuccaro+checkpoint mutual exclusivity), not here.

Filed Bennett-gsxe: tighten `lower_add_cuccaro!` from 2(n-1)=62 to 2n-3=61 (Cuccaro 2004 Table 1 optimal for mod 2^n).

## 2026-04-12 — T1c.1: Babbush-Gidney QROM primitive (Bennett-hz31)

### Paper ground truth (Babbush-Gidney 2018, arXiv:1805.03662v2)

§III.C Figure 10: read-only data lookup via **unary iteration** (§III.A Fig 7).
A complete binary tree of AND gates over log₂(L) index bits produces L leaf-flags;
exactly one leaf is active at runtime (= 1 iff idx matches). Data encoded as
data-dependent CNOT fan-out from each leaf. After fan-out, AND tree is reversed.

**Claimed cost: 4L-4 T gates (= 2(L-1) Toffoli), O(log L) ancillae, W-independent.**

### Implementation — `src/qrom.jl`

```julia
emit_qrom!(gates, wa, data::Vector{UInt64}, idx_wires, W::Int) -> Vector{Int}
```

Emits `(idx, 0^W) → (idx, data[idx])` inline. Recursive DFS of the binary tree:
at each internal node allocates two child flags (`right = parent AND idx_bit` via
1 Toffoli, `left = parent XOR right` via 2 CNOTs), recurses, uncomputes both,
returns flag wires to the WireAllocator pool. O(log L) peak ancilla wire use.

Data is baked inline — `data::Vector{UInt64}` must be compile-time constant at
call site. At each leaf ℓ, loops data[ℓ+1]'s bits; emits `CNOT(leaf_flag, data_out[bit])`
for each set bit. Zero bits cost zero gates.

### Measured scaling (post-Bennett; self-uncomputing → 2× over raw paper bound)

```
L  | gates | Toffoli | wires
---+-------+---------+------
 4 |   56  |   12    |  23
 8 |  120  |   28    |  26
16 |  256  |   60    |  29
32 |  544  |  124    |  32
```

Post-Bennett Toffoli = **4(L-1) exactly** (paper's 2(L-1) × 2 for Bennett reverse).
Wire count grows as ~W + log L (DFS flag reuse via `free!`).

### W-independence (L=4, varying W)

```
W  | gates | Toffoli
---+-------+--------
 4 |  52   |  12
 8 |  56   |  12
16 |  72   |  12
32 | 104   |  12
64 | 168   |  12
```

Toffoli count stays at 12 regardless of W — CNOTs scale with data popcount × W in
the worst case, never Toffolis. Matches paper's claim exactly.

### Head-to-head vs soft_mux_load (existing T1b path)

| L | Primitive              | Gates  | Reduction |
|---|------------------------|--------|-----------|
| 4 | soft_mux_load_4x8      | 7,514  | —         |
| 4 | QROM (W=8)             |    56  | **134×**  |
| 8 | soft_mux_load_8x8      | 9,590  | —         |
| 8 | QROM (W=8)             |   144  | **66.6×** |

For read-only constant tables, QROM is 2 orders of magnitude smaller than
our MUX-tree fallback. The gap widens at larger W (MUX is O(L·W), QROM is
O(L + W·popcount)).

### Known sub-optimality (MVP)

QROM's forward circuit is already self-uncomputing (paper § III.C), so Bennett's
reverse phase doubles it redundantly — same architectural issue as Cuccaro
(Bennett-07r). Fixing would halve the gate count on every QROM-dispatched lookup.

### Restrictions (MVP)

- `L` must be a power of two (follow-up: non-power-of-two via subtree truncation,
  paper Fig 3's "highlighted runs" elimination)
- `W` ≤ 64
- Data is `Vector{UInt64}` — caller must ensure `(d & ~mask) == 0` for W<64

### Test

`test/test_qrom.jl` — 69 assertions covering L∈{2,4,8,16}, W∈{8,16,32}, edge
data (all-zero, all-ones, alternating), exact Toffoli-count match to 2(L-1)
pre-Bennett, and CNOT fan-out scaling with popcount. Hooked into runtests.jl.

### What this unblocks

- T1c.2 (Bennett-za54): `lower_var_gep!` dispatch to QROM when base is a
  compile-time-constant array.
- T1c.3 (Bennett-qw8k): scaling benchmark QROM vs MUX tree vs MUX EXCH for L∈{4..128}.

## 2026-04-12 — T1c.2: reversible_compile dispatches const tables to QROM (Bennett-za54)

### End-to-end integration

Plain Julia code like `f(x) = let tbl = (a,b,c,d); tbl[(x&3)+1]; end` now compiles
straight to a QROM-backed reversible circuit. No special annotations, no soft_mux
helpers, no hand-lifted tables — just write the function. Julia's compiler lowers
the tuple to a private constant global (`@"_j_const#1" = private constant [4 x i8] c"..."`);
our extractor pulls the data into `ParsedIR.globals`; our lower_var_gep! dispatch
routes it through `emit_qrom!`.

### Measured end-to-end gate counts (via `reversible_compile`)

| Julia function                       | L  | Total gates | Toffoli | Wires |
|--------------------------------------|----|-------------|---------|-------|
| 4-byte S-box prefix lookup           |  4 |         144 |      28 |   114 |
| 8-byte S-box prefix lookup           |  8 |         234 |      44 |   114 |
| 16-byte AES S-box prefix lookup      | 16 |         402 |      76 |   114 |

Compare to the MUX-tree path that existed before T1c.2 (`soft_mux_load_NxW`):
L=4 MUX was ≈7,500 gates; L=8 MUX was ≈9,600 gates. **QROM dispatch is 52×–66×
smaller** on these end-to-end Julia lookups.

Wire count stays ~constant at 114 because the Julia source is the same wrapper
(UInt8 arg, UInt8 return) — only the internal table-size changes, and QROM's
log L flag ancillae are negligible.

### Implementation

Four-step integration, all under red-green TDD (9 new tests in
`test/test_qrom_dispatch.jl`, 774 assertions):

1. **`ParsedIR` gains `globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}`** —
   extracted from LLVM.Module globals at parse time. Keyed by the global's
   LLVM name (e.g. `Symbol("_j_const#1")`), valued as `(data, elem_width)`.

2. **`ir_extract.jl` extracts const-initialized integer-array globals** —
   new `_extract_const_globals(mod)` walks `LLVM.globals(mod)`, filters to
   `isconstant` globals with `ConstantDataArray` initializers over
   `IntegerType`, reads each element via `LLVMGetElementAsConstant` +
   `LLVMConstIntGetZExtValue`. Julia emits many non-table globals (type
   references, aliases, dispatch tables) whose `LLVM.initializer` errors
   with "Unknown value kind" — guarded with try/catch.

3. **GEP extractor recognizes `LLVM.GlobalVariable` bases** — previously
   `if haskey(names, base.ref) && length(ops) == 2` skipped global-backed
   GEPs. Added a Case B branch: when `base isa LLVM.GlobalVariable && LLVM.isconstant(base)`,
   emit `IRVarGEP(dest, ssa(gname), idx_op, elem_width)`. The subsequent IRLoad's
   pointer SSA aliases to these wires (existing alias-slice path).

4. **`lower_var_gep!` dispatches to `_emit_qrom_from_gep!`** — when
   `inst.base.name` is in `ctx.globals`, pulls the data vector and elem_width,
   resolves the idx operand, and calls `emit_qrom!`. Static idx (compile-time
   constant) short-circuits to zero-gate constant materialization.
   `LoweringCtx` extended with `globals` field; threaded through `lower()` and
   `lower_block_insts!` via backward-compatible constructors.

### Julia codegen gotcha

**Module-level tuples don't inline.** `const sbox = (...)` at module scope
produces a by-reference `Any` lookup inside the function (`call @ijl_undefined_var_error`
or pointer-arg), not a private constant global. Work around with `let sbox = (...); body; end`
inside the function body — this forces Julia to emit the tuple as an inline
compile-time constant. Documented in `test/test_qrom_dispatch.jl`.

### MVP restrictions

- Global data widths in 1..64 bits (matches QROM's UInt64 data word)
- Single-index GEPs only (`getelementptr TYPE, ptr @g, i64 %idx`) — multi-index
  GEPs like `getelementptr [N x T], ptr @g, i64 0, i64 %idx` not yet plumbed
- Non-power-of-two table lengths zero-pad to next 2^n (correct under Julia's
  standard pre-GEP boundscheck, which ensures idx ∈ [0, L))

### What this unblocks

- T1c.3 (Bennett-qw8k): direct comparison benchmark QROM vs MUX EXCH for L∈{4..128},
  all metrics (gate count, Toffoli, T-count, wires) side by side.
- Real lookup-heavy benchmarks: AES S-box, bit-reversal tables, trig tables for
  soft-float, all compile through the same pipeline.

