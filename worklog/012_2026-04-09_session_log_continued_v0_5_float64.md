## Session log — 2026-04-09 (continued): v0.5 Float64

### What was built

1. **Soft-float library (Phase 1 — complete)**
   - `src/softfloat/fneg.jl`: `soft_fneg(a::UInt64)::UInt64` — XOR bit 63. Trivial.
   - `src/softfloat/fadd.jl`: `soft_fadd(a::UInt64, b::UInt64)::UInt64` — full IEEE 754
     double-precision addition. Handles NaN, Inf, zero, subnormals, round-to-nearest-even.
     Uses binary-search CLZ (6 constant-shift stages) for normalization.
   - `src/softfloat/softfloat.jl`: includes fneg.jl and fadd.jl.
   - `test/test_softfloat.jl`: 1,037 tests. 10,000 random pairs bit-exact against
     Julia's native `+`. Edge cases: ±0, ±Inf, NaN, subnormals, near-cancellation.
   - All soft-float tests pass. **Bit-exact** with hardware Float64 addition.

2. **LLVM intrinsic support (Pipeline extension)**
   - `ir_extract.jl`: `_convert_instruction` now handles `call` instructions for
     known LLVM intrinsics: `@llvm.umax`, `@llvm.umin`, `@llvm.smax`, `@llvm.smin`.
     Each is lowered to `IRICmp` + `IRSelect` (compare + select).
   - LLVM optimizes `ifelse(x != 0, x, 1)` into `@llvm.umax.i64(x, 1)`. Without
     this support, the SSA variable from the intrinsic call was undefined, causing
     "Undefined SSA variable" errors.
   - `_module_to_parsed_ir` now handles vector returns from `_convert_instruction`
     (needed for the two-instruction expansion of intrinsics).

3. **Variable-amount shift support (Pipeline extension)**
   - `lower.jl`: Removed constant-shift assertion. Added `lower_var_shl!`,
     `lower_var_lshr!`, `lower_var_ashr!` — barrel-shifter implementations.
   - Each barrel shifter: `_shift_stages(W, b_len)` stages (6 for 64-bit).
     Each stage: conditional shift by 2^k via MUX. Total: ~6 × 4W = 1536 gates
     per 64-bit variable shift.
   - Tested: `var_rshift(x::Int8, n::Int8) = reinterpret(Int8, reinterpret(UInt8,x) >> (reinterpret(UInt8,n) & UInt8(7)))`.
     All 256×8 = 2048 input combinations correct. 272 gates.

4. **Phi resolution for complex CFGs (Pipeline extension — partial)**
   - `lower.jl`: Rewrote `resolve_phi_muxes!` from iterative (pair-matching) to
     recursive (partition-based). Finds a branch that cleanly partitions incoming
     values into true-set and false-set, recurses on each, MUXes results.
   - Added `phi_block` parameter: passed from `lower_phi!` through to
     `resolve_phi_muxes!`. When a block IS the branch source AND the phi block
     is one of the branch targets, correctly identifies which side the block is on.
     Critical for the LLVM `common.ret` pattern (many early returns merged via phi).
   - Added **diamond merge** handling: when some values are reachable from both
     sides of a branch (CFG diamond), resolve them once as shared and include in
     both sub-problems. Shared wires are read by both MUX branches (valid in
     reversible circuits since wires are read-only for controls).
   - Added cycle detection in `has_ancestor` (visited set) to prevent infinite
     recursion from predecessor graph cycles.

5. **soft_fadd circuit compilation (Phase 3 — partial)**
   - `soft_fadd` compiles to a reversible circuit: **87,694 gates** (4,052 NOT,
     60,960 CNOT, 22,682 Toffoli), 27,550 wires, 27,358 ancillae.
   - `soft_fneg` compiles: 322 gates (2 NOT, 320 CNOT, 0 Toffoli).
   - Simulation correct for non-overflow addition cases: 1.0+2.0, 1.0+0.5,
     3.14+2.72, 0.0+0.0, Inf+1.0, Inf+(-Inf), subtraction cases.
   - **Known failure**: overflow cases (0.5+0.5, 1.0+1.0, 0.25+0.25) return 0
     instead of the correct sum. Root cause: the L107/L112 diamond in the CFG.
     L107 branches to L110 (addition) or L112 (subtraction). Both paths merge at
     L129. Downstream values (L186, L211, L240, L257) have ancestors on BOTH sides
     of L107. When L112's cancellation check (wr==0) condition wire is 1 (because
     the subtraction result IS 0 for equal-magnitude same-sign inputs), the MUX
     incorrectly selects the cancellation return value (0) instead of the
     normal computation result.
   - **Fix needed**: The MUX tree must nest L112's check INSIDE L107's branch so
     that L107_cond=true (addition path) bypasses L112's check entirely. Current
     recursive resolver skips L107 because it has no exclusive true-side values
     (only ambiguous diamond values). A "one-sided + ambiguous" case was attempted
     but causes infinite recursion — needs further work.

6. **Test files created**
   - `test/test_softfloat.jl`: 1,037 tests for soft_fneg and soft_fadd bit-exactness.
   - `test/test_float_circuit.jl`: Circuit compilation + simulation tests for
     soft_fneg and soft_fadd. Currently has known failures for overflow cases.

### Key bugs encountered and fixed

1. **LLVM umax intrinsic**: LLVM optimized `ifelse(x != 0, x, 1)` into
   `@llvm.umax.i64(x, 1)`. Our pipeline skipped `call` instructions, leaving the
   SSA variable undefined. Fix: handle known intrinsics by expanding to icmp+select.

2. **12-way phi resolution**: LLVM's `common.ret` block has a phi with 12 incoming
   values from early returns. The old iterative resolver (innermost-first pair
   matching) failed because some incoming blocks are the branch SOURCE (they go
   directly to common.ret). Fix: pass `phi_block` through the resolver and use it
   to determine which side of a branch the source block is on.

3. **CFG diamond merge**: Blocks L207.thread and L207 both lead to L215, creating
   a diamond. Values downstream of L215 are reachable from both sides of L129's
   branch. The recursive resolver's clean-partition check fails. Fix: detect
   ambiguous (both-side) values, resolve them once as shared, include the shared
   result in both sub-problems.

4. **Overflow simulation bug (OPEN)**: For equal-magnitude same-sign addition
   (0.5+0.5), the subtraction path also computes (wa - wb = 0). L112's condition
   wire (wr==0) is true even though the addition path was taken. The MUX tree
   needs L107's branch to guard L112's check. The resolver can't place L107
   correctly because all downstream values are ambiguous (diamond). Attempted fix
   (one-sided + ambiguous → use ambiguous as the empty side) causes infinite
   recursion. Further work needed — likely requires tracking which branches have
   already been used in the recursion or a fundamentally different phi resolution
   strategy for these cases.

### Gate count reference (new entries)

| Function | Width | Gates | NOT | CNOT | Toffoli | Wires |
|----------|-------|-------|-----|------|---------|-------|
| soft_fneg | i64 | 322 | 2 | 320 | 0 | |
| soft_fadd | i64 | 87694 | 4052 | 60960 | 22682 | 27550 |
| var_rshift | i8 | 272 | 6 | 202 | 64 | |

### Process notes
- Followed red-green TDD throughout: wrote test_softfloat.jl first (RED, stubs),
  then implemented (GREEN). Wrote test_float_circuit.jl (RED, compilation fails),
  then added pipeline features.
- Each pipeline change verified against full existing test suite (17 files, 10K+
  assertions) before proceeding.
- PRD: BennettIR-v05-PRD.md. Approach B (pure-Julia soft-float wrapper).

### Architecture decisions

**Soft-float as pure Julia**: The soft_fadd function is a standard Julia function
taking UInt64 bit patterns. It uses only integer operations (shifts, adds, bitwise,
comparisons, ifelse). The existing pipeline compiles it without any float-specific
code. The "floating point" happens entirely at the Julia level — the pipeline sees
only integer operations on 64-bit values.

**Barrel shifter for variable shifts**: Each stage conditionally shifts by 2^k
using a MUX. 6 stages for 64-bit (covering shifts 1,2,4,8,16,32). Cost: ~1536
gates per variable shift (6 stages × 256 gates per MUX).

**Recursive phi resolution**: Replaced iterative pair-matching with recursive
partitioning. Each recursion level finds a branch that splits the incoming values
into two non-empty groups, recurses on each, and MUXes the results. Handles
N-way phis naturally (reduces N→1 via log2(N) levels for balanced trees, up to
N-1 levels for degenerate cases).

**Diamond merge in phi resolution**: When values are reachable from both sides of
a branch (CFG diamond after an if-else merge), resolve them once and share the
result in both sub-calls. The shared wires are read-only (CNOT/Toffoli controls),
so sharing is safe in reversible circuits.

