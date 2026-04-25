## Research: overflow simulation bug — "false path" problem

### The bug

The overflow simulation bug (0.5+0.5 returns 0 instead of 1.0) is an instance of
the **"false path sensitization"** problem, well-known in hardware synthesis
(VLSI/FPGA). In a branchless/speculative datapath, ALL paths are computed. A
condition wire from the subtraction path (`wr==0`) evaluates to true even when the
addition path was "taken" (via MUX selection), because the subtraction of two equal
mantissas IS zero. The MUX tree doesn't scope this condition correctly — L112's
cancellation check fires without being guarded by L107's same-sign check.

Reference: Bergamaschi (1992), "The Effects of False Paths in High-Level Synthesis",
IEEE. False paths occur due to sequences of conditional operations where the
combination of conditions required to activate the path is logically impossible.

### Literature survey: no existing reversible compiler handles this

No published reversible compiler handles N-way phi nodes from complex CFGs:

- **ReVerC / Revs** (Parent, Roetteler, Svore — Microsoft, CAV 2017): Compiles F#
  subset to Toffoli networks. NO dynamic control flow — restricted to straight-line
  computation. Uses Bennett compute-copy-uncompute on DAGs, not CFGs.
  Ref: "Verified Compilation of Space-Efficient Reversible Circuits" (Springer).

- **Janus** (Yokoyama, Gluck, 2007): Reversible language where conditionals have
  EXIT ASSERTIONS (`if p then B1 else B2 fi q`) that disambiguate branches at merge
  points. Not applicable to LLVM IR where this info is erased into phi nodes.
  Ref: "Principles of a Reversible Programming Language" (ACM).

- **VOQC / SQIR** (Hicks et al., POPL 2021): Verified optimizer for already-
  synthesized gate-level quantum circuits. Does not deal with SSA/phi/CFG compilation.
  Ref: "A Verified Optimizer for Quantum Circuits" (arXiv:1912.02250).

- **XAG-based compilation** (Meuli, Soeken, De Micheli, 2022): Boolean function
  decomposition into XOR-AND-Inverter Graphs → Toffoli. Operates on Boolean functions,
  not CFGs. Ref: Nature npj Quantum Information (2021).

- **Bennett's pebble game**: Applies to straight-line DAGs. No standard extension
  to CFGs with diamond merges. Ref: Meuli et al. (2019), Chan (2013).

**Our implementation is in uncharted territory.** No published system handles
converting a multi-way phi node from a complex CFG into a correct MUX tree
of reversible gates.

### Quantum floating-point literature

- **Haener, Soeken, Roetteler, Svore (2018)**: "Quantum circuits for floating-point
  arithmetic" (RC 2018, SpringerLink). Two approaches: automatic synthesis from
  Verilog and hand-optimized circuits. Each Toffoli = 7 T-gates in T-depth 3. This
  is the closest published work to what we're doing. They do NOT handle NaN/Inf/zero.

- **Nguyen & Van Meter (2013)**: "A Space-Efficient Design for Reversible Floating
  Point Adder in Quantum Computing" (arXiv:1306.3760). IEEE 754 single-precision.
  Their fault-tolerant KQ is ~60x that of 32-bit fixed-point add. Our 87,694 gates
  for Float64 aligns: their formula predicts ~84K for double-precision (350 gates
  for Int64 add × 60 × ~4x for width doubling ≈ 84K).

- **Gayathri et al. (2021)**: "T-count optimized quantum circuit for floating point
  addition and multiplication" (Springer). 92.79% T-count savings over Nguyen/Van
  Meter, 82.74% KQ improvement over Haener et al.

None of these handle special cases (NaN, Inf, zero, subnormal). Our soft_fadd is
more complete than any published quantum FP circuit.

### Existing soft-float implementations (all branchy)

- **LLVM compiler-rt `fp_add_impl.inc`** (`__adddf3`): 13+ if/else with early
  returns for NaN, Inf, zero, subnormal.
- **Berkeley SoftFloat 3** (`f64_add`): Dispatches on sign into addMags/subMags,
  each with 7-10 branches plus gotos.
- **GCC libgcc `soft-fp`**: Macro-heavy, expands to equivalent branchy code.
- **GPU shaders**: Emulate double precision via two single-precision floats
  (double-single arithmetic), relying on GPU's native FP for special cases.

No existing soft-float implementation is branchless. All assume CPUs with branch
prediction. For circuits, branchless is the standard approach.

### Hardware synthesis context

**Two-path FP adder architecture** (standard in FPGA/ASIC):
- "Close path" (effective subtraction, exp diff 0 or 1, needs full CLZ)
- "Far path" (all other cases, at most 1-bit normalization)
- Both computed in parallel, MUX selects. Natural fit for reversible circuits.
- Ref: "Dual-mode floating-point adder architectures" (Elsevier, 2008).

**FloPoCo** (Floating-Point Cores Generator, flopoco.org): Generates VHDL/Verilog
FP cores for FPGAs. NOT IEEE 754 compliant (omits NaN/Inf/subnormal). Uses
MUX-tree datapath internally. Double-precision adder: ~261 LUTs on Kintex-7.

### Three fix options (ranked by practicality)

#### Option A: Rewrite soft_fadd to be fully branchless (RECOMMENDED)

Replace all `if/else/return` with `ifelse` selects. Compute ALL results (NaN, Inf,
zero, normal) unconditionally, select at end with a chain of `ifelse`.

**How:**
1. Compute all special-case results unconditionally
2. Compute all predicates (is_nan, is_inf, is_zero, etc.)
3. Compute BOTH `wa + wb_aligned` AND `wa - wb_aligned`, select with `ifelse(sa==sb, add_result, sub_result)`
4. Replace the exact-cancellation early return with `ifelse(wr==0, UInt64(0), packed_result)` at the end
5. Convert normalization CLZ `if` statements to `ifelse` (already nearly branchless)
6. Convert subnormal underflow and overflow to `ifelse`
7. Chain final select: `ifelse(is_nan, QNAN, ifelse(is_inf, inf_result, ifelse(is_zero, zero_result, normal_result)))`

**Pros:**
- LLVM emits `select` instructions → NO phi nodes → no resolution needed
- "Correct by construction" — eliminates the entire class of false-path bugs
- Pipeline already handles `select` via `lower_select!`/`lower_mux!`
- Estimated gate cost: ~90,000-95,000 gates (~5-10% overhead). Modest because
  the dominant cost is mantissa arithmetic (same either way). Extra: ~1,400 gates
  for computing both add+sub, ~1,200-1,600 for parallel special cases,
  ~1,344 for 7× 64-bit MUX selection chain, ~1,152 for normalization stage MUXes.

**Cons:**
- All paths always computed (but this is inherent to reversible circuits anyway)
- Doesn't fix the phi resolver for future complex functions

#### Option B: Path-predicate phi resolution (principled algorithm)

Replace the reachability-based partitioning in `resolve_phi_muxes!` with explicit
**path predicates** — 1-bit condition wires computed for each block in the CFG.

**Algorithm (from Gated SSA / Psi-SSA literature):**
1. Walk blocks in topological order. For each block, compute `block_pred[label]`
   as a wire (1-bit).
2. Entry block: `block_pred[:entry] = [constant 1]`
3. Unconditional branch from B to T: `block_pred[T] = block_pred[B]`
4. Conditional branch from B (cond, T, F):
   - `block_pred[T] = AND(block_pred[B], cond)`
   - `block_pred[F] = AND(block_pred[B], NOT(cond))`
5. Block with multiple predecessors (merge/diamond):
   - `block_pred[B] = OR(block_pred[p1], block_pred[p2], ...)`
6. For the phi with incoming (val_i, block_i):
   - `result = MUX(block_pred[b1], val1, MUX(block_pred[b2], val2, ...))`

**Why it works:** Each path predicate is true for exactly one execution path.
The MUX chain selects the right value regardless of diamond merges. No ambiguity.

**Theoretical basis:**
- **Gated SSA** (Havlak, 1993): Replaces phi with `gamma(c, x, y)` carrying the
  branch condition explicitly. "Construction of Thinned Gated Single-Assignment
  Form" (Springer, LNCS 768).
- **Psi-SSA** (Stoutchinin & Gao, CC 2004): Predicated merge nodes
  `psi(p1:v1, p2:v2, ..., pn:vn)` with mutually exclusive, exhaustive predicates.
  "If-Conversion in SSA Form" (Springer, LNCS 2985).
- **Dominator tree approach**: The correct MUX nesting order follows the dominator
  tree. If branch X dominates branch Y, X's MUX must be outer, Y's inner.

**Pros:**
- Correct for ANY CFG (arbitrary diamonds, multi-way phis, complex nesting)
- Makes the resolver robust for all future functions
- Well-founded in compiler theory

**Cons:**
- More engineering work (compute path predicates during lowering, wire AND/OR/NOT
  gates for each predicate)
- Extra gates for predicate computation (AND + NOT per conditional branch, OR per
  merge point). For 12-way phi with ~20 branches: ~20 AND gates + ~20 NOT gates +
  ~10 OR gates = ~50 extra 1-bit gates. Negligible.
- Predicate wires become ancillae (need to be uncomputed by Bennett)

#### Option C: Custom LLVM pass (aggressive if-conversion)

Use LLVM.jl to run additional optimization passes on the IR after `optimize=true`,
specifically targeting branch-to-select conversion.

**How:**
1. `extract_ir(f, types; optimize=true)` → optimized IR string
2. Parse into `LLVM.Module` (already done in `extract_parsed_ir`)
3. Run custom pass pipeline: `FlattenCFG`, aggressive `SimplifyCFG` with high
   speculation threshold, or `SpeculativeExecution`
4. Walk the transformed module (should have more selects, fewer branches)

**LLVM specifics:**
- `SimplifyCFG`'s `FoldTwoEntryPHINode` only handles 2-entry phis in simple
  diamonds. Default `TwoEntryPHINodeFoldingThreshold` = 4 instructions.
- `UnifyFunctionExitNodes` (`-mergereturn`) is what CREATES the `common.ret`
  pattern. Undoing it requires splitting returns back out.
- LLVM's if-conversion is conservative (won't speculate expensive code). For
  reversible circuits, ALL paths are computed anyway, so the "cost" concern
  doesn't apply. A custom pass could aggressively convert without cost limits.

**Pros:**
- Eliminates phis at the LLVM level before our pipeline sees them
- Leverages LLVM's existing infrastructure

**Cons:**
- Significant LLVM engineering (custom pass development)
- LLVM pass API changes between versions (fragile)
- Doesn't help if LLVM introduces new patterns in future versions

#### Option D: Compile with optimize=false

**What happens:** Without optimization, LLVM IR has `alloca`/`load`/`store` for all
local variables (no `mem2reg` pass). Each `return` is its own `ret` instruction.
No `common.ret`, no multi-way phi.

**Problems:**
- Pipeline doesn't handle `alloca`/`load`/`store` — would need a memory model
- IR is much larger (no constant folding, no dead code elimination)
- Redundant computation → much larger circuits

**A middle ground:** Run partial optimization: `mem2reg` (eliminate alloca/load/store)
+ basic `simplifycfg` (clean up trivial blocks) but NOT full optimization that
creates `common.ret`. Requires using LLVM.jl API for custom pass pipeline.

### Recommendation

**Option A (branchless rewrite) for the immediate fix.** It's the smallest code
change, eliminates the entire class of false-path bugs, and the gate overhead is
negligible (~5-10%). This is the standard approach for circuit implementations of
floating-point arithmetic (FloPoCo, FPGA adders, quantum FP papers all use
branchless MUX-tree datapaths).

**Option B (path predicates) for long-term robustness.** Implement as a future
enhancement to make the phi resolver correct for arbitrary CFGs. This is the
principled solution grounded in Gated SSA / Psi-SSA theory.

