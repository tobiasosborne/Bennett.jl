## Session log — 2026-04-10: branchless soft_fadd (Option A)

### Branchless rewrite — completed

Rewrote `soft_fadd` to be fully branchless (Option A from false-path analysis).
Every `if/else/return` replaced with `ifelse`. All paths computed unconditionally,
final result selected via priority chain at the end.

**Key changes:**
1. Special-case predicates (`a_nan`, `b_nan`, `a_inf`, `b_inf`, `a_zero`, `b_zero`)
   computed unconditionally upfront
2. Both `wr_add = wa + wb_aligned` and `wr_sub = wa - wb_aligned` computed
   unconditionally, selected with `ifelse(same_sign, wr_add, wr_sub)`
3. Exact cancellation handled as a predicate (`exact_cancel`), not an early return —
   substitutes `wr = 1` as a sentinel to avoid undefined normalization on zero
4. Normalization CLZ stages: each `if` → `ifelse` on the condition bit
5. Subnormal/overflow/rounding: all computed unconditionally, selected at end
6. Final select chain in priority order: NaN > Inf > Zero > exact_cancel >
   subnormal flush > exp overflow > normal

**Gotchas:**
- `UInt64(negative_int64)` throws `InexactError` — must clamp Int64 values to
  non-negative range before UInt64 conversion even when the result will be
  overridden by the select chain. Julia evaluates all `ifelse` arguments eagerly.
  Two places needed clamping: subnormal shift amount (`shift_sub = 1 - result_exp`,
  negative for normal numbers) and exponent packing (`exp_after_round`, negative
  for subnormal results).
- `clamp` is branchless in Julia (uses `min`/`max` → LLVM `select`), safe to use.
- Alignment shift mask `(1 << d) - 1` needs d clamped to [1,63] to avoid shift-by-zero
  or shift-by-64 UB.

**Gate counts (branchless vs branching):**

| Metric  | Before   | After    | Delta  |
|---------|----------|----------|--------|
| Total   | 87,694   | 94,426   | +7.7%  |
| NOT     | 4,052    | 5,218    | +28.8% |
| CNOT    | 60,960   | 64,714   | +6.2%  |
| Toffoli | 22,682   | 24,494   | +8.0%  |

~7.7% total overhead — within predicted 5-10%. The cost is computing both add/sub
paths and the extra select chain. Modest because mantissa arithmetic (the dominant
cost) is identical either way.

**Result:** All 1,037 library tests pass (bit-exact). All 124 circuit tests pass —
including the 7 equal-magnitude same-sign cases that previously failed due to
false-path sensitization. The entire class of false-path bugs is eliminated for
soft_fadd.

### soft_fmul — completed

Implemented `soft_fmul` (IEEE 754 double-precision multiplication) branchless from
the start. Key design:

1. Sign = XOR of input signs
2. Exponent = ea + eb - 1023 (bias)
3. 53x53 mantissa multiply via schoolbook decomposition into four half-word partial
   products (27x26 bits each, fits in UInt64 without overflow). Assembled into
   128-bit product (prod_hi:prod_lo) with add-with-carry.
4. Extract top 56 bits (53 mantissa + 3 GRS) based on whether MSB is at bit 105
   or 104 of the product
5. CLZ normalization (same 6-stage binary search as soft_fadd)
6. Rounding, subnormal handling, overflow — same structure as soft_fadd
7. Final select chain: NaN > Inf*0=NaN > Inf > Zero > overflow > normal

**New LLVM intrinsic: `llvm.fshl`/`llvm.fshr` (funnel shifts).**
LLVM optimizes `(a << N) | (b >> (64-N))` into `@llvm.fshl.i64(a, b, N)`. Added
decomposition in `ir_extract.jl`:
- `fshl(a, b, sh)` → `(a << sh) | (b >> (w - sh))`
- `fshr(a, b, sh)` → `(a << (w - sh)) | (b >> sh)`
Each decomposes into 3 IRBinOps (shl, sub, lshr, or).

**Gate counts:**

| Operation | Total   | NOT   | CNOT    | Toffoli  |
|-----------|---------|-------|---------|----------|
| soft_fneg | 322     | 2     | 320     | 0        |
| soft_fadd | 94,426  | 5,218 | 64,714  | 24,494   |
| soft_fmul | 265,010 | 4,960 | 155,828 | 104,222  |

soft_fmul is ~2.8x soft_fadd. The 104,222 Toffoli gates are dominated by the
53x53 mantissa multiply (schoolbook: O(53^2) = 2,809 full-adder cells, each
requiring multiple Toffoli gates in the reversible ripple-carry implementation).

PRD estimated 20,000-50,000 gates for soft_fmul. Actual: 265,010. The estimate
was for the mantissa multiply alone; the full pipeline (unpack, normalize, round,
repack, branchless select chain) adds significant overhead. The branchless approach
also computes both normalization paths unconditionally.

**Result:** 1,041 library tests pass (bit-exact). 238 circuit tests pass (including
113 soft_fmul circuit tests). All ancillae verified zero. Full test suite green.

### Float-aware frontend + end-to-end polynomial — completed

Implemented `reversible_compile(f, Float64)` and the full end-to-end pipeline.

**Architecture — SoftFloat dispatch + gate-level call inlining:**

1. `SoftFloat` wrapper struct redirects `+`, `*`, `-` to `soft_fadd`/`soft_fmul`/
   `soft_fneg` on UInt64 bit patterns. Julia inlines the tiny wrapper methods,
   leaving direct `call @soft_fmul(i64, i64)` and `call @soft_fadd(i64, i64)`
   instructions in the LLVM IR.

2. New `IRCall` instruction type in `ir_types.jl` — represents a call to a known
   Julia function that should be compiled and inlined at the gate level.

3. `ir_extract.jl` recognizes calls to `soft_fadd`/`soft_fmul`/`soft_fneg` in
   the LLVM IR (by name matching) and produces `IRCall` instructions.

4. `lower_call!` in `lower.jl` handles `IRCall` by:
   a. Pre-compiling the callee via `extract_parsed_ir` + `lower`
   b. Offsetting all callee wires into the caller's wire space
   c. CNOT-copying caller arguments → callee input wires
   d. Inserting callee's forward gates with wire remapping
   e. Setting callee's output wires as the caller's result

5. `extract_parsed_ir` now uses `dump_module=true` to include function declarations
   needed for the module parser to accept call instructions. `extract_ir` (for
   debugging/regex parser) still uses single-function mode.

**New LLVM intrinsic support:**
- `llvm.fshl` / `llvm.fshr` (funnel shifts) — decomposed to `shl` + `lshr` + `or`

**Bug fix in branchless soft_fadd:**
- Zero + nonzero special case incorrectly considered the swap flag. Fixed to
  return the original non-zero operand directly: `ifelse(a_zero & !b_zero, b, result)`.

**Gate counts (end-to-end):**

| Function                         | Total   | NOT    | CNOT    | Toffoli  |
|----------------------------------|---------|--------|---------|----------|
| soft_fneg                        | 322     | 2      | 320     | 0        |
| soft_fadd                        | 93,402  | 5,218  | 63,946  | 24,238   |
| soft_fmul                        | 265,010 | 4,960  | 155,828 | 104,222  |
| **x²+3x+1 (Float64, end-to-end)** | **717,680** | **20,380** | **440,380** | **256,920** |

PRD estimated 70,000-130,000 for the polynomial. Actual: 717,680. The estimate assumed
soft_fadd/soft_fmul would be 5K-50K gates. Actual soft_fadd=93K, soft_fmul=265K. The
polynomial calls 2 fmul + 2 fadd = 2×265K + 2×93K = 716K gates plus overhead for
constant encoding and wire copying. The gate count is dominated by the 53×53 mantissa
multiplier (schoolbook O(n²) in the reversible ripple-carry adder implementation).

**Gotchas:**
- `@noinline` on SoftFloat methods is WRONG — it prevents Julia from inlining even
  the tiny wrapper code, producing struct-passing IR with `alloca`/`store`/`load`.
  Without `@noinline`, Julia inlines the wrappers and leaves clean `call @soft_fmul(i64, i64)`.
- `dump_module=true` is required for `extract_parsed_ir` (module parser needs function
  declarations for calls), but breaks the legacy regex parser. Split: `extract_ir` uses
  single-function mode, `extract_parsed_ir` uses `dump_module=true`.
- The `_name_counter` global must be saved/restored around callee compilation in
  `lower_call!` to avoid SSA name collisions between caller and callee.

**Result:** 61 end-to-end polynomial tests pass (all 256-value random sweep + edge cases).
Full test suite green: all prior tests pass. All ancillae verified zero.

### Path-predicate phi resolution (Option B) — completed

Replaced the reachability-based phi resolver with an explicit path-predicate system.
This is the principled, general solution grounded in Gated SSA / Psi-SSA theory.

**Architecture:**

1. **Block predicates:** During lowering, each basic block gets a 1-bit predicate wire
   indicating whether execution reached that block. Entry block predicate = 1.
   Computed from predecessors: conditional branches produce AND(pred, cond) and
   AND(pred, NOT(cond)); unconditional branches propagate pred; merge blocks OR
   all incoming predicates.

2. **Edge predicates:** For phi resolution, the relevant predicate is not the
   predecessor block's predicate, but the EDGE predicate — which specific branch
   from the predecessor led to the phi's block. Computed per-edge in
   `resolve_phi_predicated!`.

3. **MUX chain:** Chain of MUXes controlled by edge predicates. Since predicates are
   mutually exclusive, exactly one fires. Correct for ANY CFG by construction.

**New helper gates:**
- `_and_wire!(a, b)`: 1 Toffoli gate
- `_or_wire!(a, b)`: 1 CNOT + 1 CNOT + 1 Toffoli = 3 gates (via a XOR b XOR (a AND b))
- `_not_wire!(a)`: 1 NOT + 1 CNOT = 2 gates

**Key bug found during implementation:**
- `block_pred[from_block]` is WRONG for phi resolution when from_block has a
  conditional branch. The block predicate says "this block was reached" but the phi
  needs "this block was reached AND its branch to MY block was taken." For blocks
  with conditional branches, the block predicate is always true for the entry block,
  causing all phi values to select the entry block's value. Fixed by computing edge
  predicates per-incoming-value in the phi resolver.

**Also fixed:**
- `llvm.abs` intrinsic support (decomposes to sub + icmp sge + select)
- Three-way if/elseif/else patterns now compile correctly

**Gate overhead:** ~5-15 extra gates per conditional branch for predicate computation
(AND, NOT, OR gates on 1-bit wires). Negligible compared to function gate counts.

**Result:** Full test suite passes (all existing tests + 1,796 new predicated phi tests).
Old reachability-based resolver retained but not used by default. The predicated
resolver is now the default for all phi resolution.

### Full session summary — 2026-04-10

**24 commits, 13 beads issues closed, ~2,500 lines of new code.**

#### v0.5 completed
- Branchless `soft_fadd` (eliminates false-path sensitization class of bugs)
- `soft_fmul` (265K gates, branchless from start)
- Float64 frontend: `reversible_compile(f, Float64)` via SoftFloat dispatch + IRCall
- End-to-end: `x²+3x+1` on Float64 compiles to 717,680 gates
- Path-predicate phi resolution (correct for all CFGs, replaces reachability-based)

#### v0.6 completed
- `extractvalue` instruction (wire selection from aggregates)
- `soft_fsub` (= fadd + fneg), `soft_fcmp_olt`, `soft_fcmp_oeq`
- `soft_fdiv` — IEEE 754 division via 56-iteration restoring division, branchless
- General `register_callee!` API for gate-level function inlining
- Integer division: `udiv`/`sdiv`/`urem`/`srem` via soft_udiv + widen/truncate
- LLVM intrinsics: `llvm.abs`, `llvm.fshl`, `llvm.fshr`
- SoftFloat extended: `+`, `-`, `*`, `/`, `<`, `==` operators

#### v0.7 completed
- NTuple input via static memory flattening: pointer params → flat wire arrays,
  GEP → wire offset, load → CNOT copy. `dereferenceable(N)` attribute detection.

#### v0.8 infrastructure
- Dependency DAG extraction from gate sequences (`extract_dep_dag`)
- Knill pebbling recursion (Theorem 2.1): exact dynamic programming, verified
  F(100,50)=299 (1.5x), F(100,10)=581 (2.92x)
- `pebbled_bennett()` — correct and reversible but schedule doesn't yet reduce
  wire count (see design insight below)
- WireAllocator with `free!` for wire reuse (pairing heap pattern from ReVerC)
- Activity analysis: `constant_wire_count` via forward dataflow (polynomial: 4 constants)
- Cuccaro in-place adder (2004): 1 ancilla instead of 2W, 44 gates for W=8,
  verified bit-exact for all inputs. Not yet integrated into main pipeline.

#### Literature
- 11 papers downloaded to `docs/literature/`, all claims stringmatched to paper text
- 5 reference codebases cloned to `docs/reference_code/` (gitignored):
  ReVerC, RevKit, Unqomp, Enzyme.jl, reversible-sota
- Survey document: `docs/literature/SURVEY.md`

#### Key design insights discovered

**Pebbling ≠ gate schedule.** The Knill pebbling game optimizes peak simultaneously-live
pebbles (= live wires), not total gate count. Converting Knill's recursion into an
actual wire-reducing schedule requires tracking which wires are live at each point
in the interleaved forward/reverse schedule and freeing them via `WireAllocator.free!`.
The standard pebbling game puts ONE pebble on the output; Bennett needs ALL gates
applied simultaneously for the copy. These are related but different optimization
problems. The PRS15 EAGER cleanup (Algorithm 2) is the practical solution.

**In-place ops need liveness.** The Cuccaro adder computes b += a in-place (1 ancilla
vs 2W). But the current pipeline always allocates fresh output wires (SSA semantics).
Using in-place ops requires knowing when an operand's value is no longer needed
(last-use liveness analysis on the SSA variable graph). This is the same information
needed for MDD eager cleanup.

**Activity analysis identifies ~1-2% constant wires.** For polynomial x²+3x+1, only
4 out of 249 ancillae carry compile-time constants. The optimization potential from
eliminating these is small. The big win is from pebbling (5.3x on SHA-2 per PRS15)
and in-place operations (Cuccaro: 1 ancilla vs 2W per addition).

## Handoff: instructions for next session

### Beads issue status

Run `bd list` and `bd ready` to see current state. 7 issues remain, all RESEARCH:

| Issue | Priority | Description | What to do |
|-------|----------|-------------|------------|
| Bennett-6lb | P1 | MDD + EAGER cleanup | **MOST IMPORTANT.** Connect pebbling DAG + Knill recursion + WireAllocator.free! into an actual ancilla-reducing bennett(). The key challenge: the standard pebbling game assumes a 1D chain, but real circuits have a DAG. Need to linearize the DAG (topological order) then apply Knill's recursion to the linearized sequence. Alternatively, implement PRS15 Algorithm 2 (EAGER cleanup) which works directly on the MDD graph. |
| Bennett-282 | P1 | Reversible persistent memory | Design a reversible red-black tree from Okasaki 1999. Papers: docs/literature/memory/Okasaki1999_redblack.pdf, AxelsenGluck2013_reversible_heap.pdf. Start with a Julia implementation, then compile through the pipeline. |
| Bennett-5i1 | P2 | SAT pebbling (Meuli) | Encode pebbling game as SAT using Z3.jl or PicoSAT.jl. Variables p_{v,i}. Paper: docs/literature/pebbling/Meuli2019_reversible_pebbling.pdf. |
| Bennett-e6k | P2 | EXCH-based memory | Implement EXCH (swap) for reversible load/store per AG13. Paper: docs/literature/memory/AxelsenGluck2013_reversible_heap.pdf. |
| Bennett-0s0 | P3 | Sturm.jl integration | Connect to Sturm.jl's `when(qubit) do f(x) end`. Requires controlled circuit wrapping. |
| Bennett-dnh | P3 | QRAM | Variable-index array access. Deferred. |
| Bennett-nw1 | P3 | Hash-consing | Maximal sharing for reversible heap. Deferred. |

### Critical files to know

| File | Purpose |
|------|---------|
| `src/Bennett.jl` | Module entry, exports, SoftFloat type, `reversible_compile` |
| `src/ir_extract.jl` | LLVM IR → ParsedIR (two-pass name table, intrinsic expansion, IRCall) |
| `src/ir_types.jl` | All IR instruction types (IRBinOp, IRCall, IRPtrOffset, IRLoad, etc.) |
| `src/lower.jl` | ParsedIR → gates (phi resolution, block predicates, div routing) |
| `src/bennett.jl` | Bennett construction (forward + copy + reverse) |
| `src/pebbling.jl` | Knill recursion + pebbled_bennett (WIP schedule) |
| `src/dep_dag.jl` | Dependency DAG extraction from gate sequences |
| `src/wire_allocator.jl` | Wire allocation with free! for reuse |
| `src/adder.jl` | Ripple-carry + Cuccaro in-place adder |
| `src/divider.jl` | soft_udiv/soft_urem (restoring division) |
| `src/softfloat/` | fadd, fsub, fmul, fdiv, fneg, fcmp (all branchless) |
| `docs/literature/SURVEY.md` | Literature survey with verified claims |
| `docs/reference_code/` | ReVerC, RevKit, Unqomp, Enzyme.jl (gitignored) |

### How to run

```bash
cd Bennett.jl
julia --project -e 'using Pkg; Pkg.test()'     # full test suite
julia --project -e 'using Bennett; ...'          # REPL
bd ready                                          # see available work
bd show Bennett-6lb                               # details on MDD issue
```

### Rules (from CLAUDE.md)

- Red-green TDD: write test first, watch it fail, implement, pass
- WORKLOG: update with every step, gotcha, learning
- Ground truth: all papers in docs/literature/, claims stringmatched
- Beads: use `bd` for all tracking, not TodoWrite
- 3+1 agents for core changes (ir_extract, lower, bennett)
- Fail fast: assertions, not silent failures
- Push before stopping: work is not done until `git push` succeeds
   robustness. Compute block predicates during lowering, use for phi resolution.

