## 2026-04-10 — Switch instruction + reversible memory research (Bennett-282)

### Switch instruction added

`LLVMSwitch` is now handled by converting to cascaded `icmp eq` + `br` blocks
at the IR extraction level (`_expand_switches` post-pass). Phi nodes in target
blocks are patched to reference the correct synthetic comparison blocks.

Test: `select3` (3-case switch on Int8) — 312 gates, correct for all inputs.

### Reversible memory research findings

**What works now for memory:**
- NTuple input via pointer flattening (dereferenceable attribute) ✓
- Constant-index GEP + load (tuple field access) ✓
- Dynamic NTuple indexing via if/elseif chain + optimize=false ✓ (546 gates for 4-element array_get)
- Dynamic switch-based indexing with optimize=true ✓ (for scalar-return functions)
- Tuple return with optimize=true ✓ (swap_pair, complex_mul_real)

**Blockers for full reversible memory:**
1. **Pointer-typed phi nodes**: When optimizer merges NTuple GEP results via switch,
   the phi merges pointers (not integers). `_iwidth` can't handle PointerType.
   Fix: skip pointer phi, resolve to underlying load values instead.
2. **sret calling convention**: Functions returning tuples with optimize=false use
   hidden pointer argument for return. Compiler doesn't handle sret GEPs.
3. **No store instruction**: `IRStore` not implemented (skipped in ir_extract.jl).

**Literature survey (papers in docs/literature/memory/):**
- Okasaki 1999: functional red-black tree, O(log n) insert via path copying.
  Key insight: persistence = ancilla preservation for Bennett uncomputation.
- Axelsen/Glück 2013: EXCH-based reversible heap. Linearity (ref count = 1)
  enables automatic GC. EXCH (register ↔ memory swap) is the fundamental
  reversible memory operation.
- Mogensen 2018: maximal sharing via hash-consing prevents exponential blowup.
  Reference counting integrates with reversible deallocation.

**Recommended path for Bennett-282:**
1. Implement pointer-phi resolution (handle PointerType in phi by resolving
   to the underlying load values — the pointer itself is just an address, the
   useful value is the loaded integer)
2. This enables: NTuple + dynamic indexing + tuple return, all with optimizer on
3. Then implement array_exch (reversible EXCH for array elements) as a pure
   Julia function compiled through the pipeline
4. Gate cost measurement for array operations of different sizes
5. Persistent red-black tree as a pure Julia implementation (future)

### Gate cost reference for reversible memory operations

| Operation | Size | Gates | Wires | Ancillae | Notes |
|-----------|------|-------|-------|----------|-------|
| MUX array get | 4×Int8 | 394 | 177 | 129 | Select via bit-masking |
| MUX array get | 8×Int8 | 746 | 313 | 233 | 3-level MUX tree |
| Static EXCH (idx=0) | 4×Int8 | 442 | 321 | — | Swap a0 ↔ val |
| MUX array EXCH | 4×Int8 | 1,402 | 617 | — | Dynamic reversible write |
| Tree lookup | 3 nodes | 1,292 | 470 | — | BST search, 2 levels |
| **RB tree insert** | 3 nodes | **71,424** | 21,924 | 21,732 | Full Okasaki balance |
| select3 (switch) | Int8→Int8 | 312 | — | — | 3-case switch |
| array_get (branch) | 4×Int8 | 546 | 216 | — | optimize=false, if/elseif |

### Research conclusion: reversible memory cost hierarchy

**For small fixed-size arrays (N ≤ 16): MUX-based EXCH wins.** 1,402 gates for
N=4 dynamic write. Cost scales as O(N × W × log N).

**For dynamic-size collections: Okasaki RB tree.** 71,424 gates for 3-node insert
with balance. The 50× overhead vs MUX comes from: (1) pointer indirection (MUX
to select node by index), (2) comparison chains at each tree level, (3) balance
pattern matching (4 cases), (4) node field packing/unpacking on UInt64.

**Persistence = reversibility.** Each tree insert produces a NEW tree version.
The old version (shared structure via path copying) is the ancilla state for
Bennett uncomputation. This is the bridge between functional data structures
and quantum/reversible computing:
- Forward: insert creates new version (ancilla = old version)
- Copy: CNOT the output to dedicated wires
- Reverse: undo insert (old version restores from ancilla)

### LLVM intrinsic coverage expansion

Added 5 intrinsics to ir_extract.jl: ctpop, ctlz, cttz, bitreverse, bswap.
All expand to cascaded IR instructions (no new lowering needed).

| Intrinsic | Width | Gates | Approach |
|-----------|-------|-------|----------|
| ctpop | i8 | 818 | Cascaded bit-extract + add |
| ctlz | i8 | 1,572 | LSB→MSB cascade select |
| cttz | i8 | 1,572 | MSB→LSB cascade select |
| bitreverse | i8 | 710 | Per-bit extract + place + OR |
| bswap | i16 | 430 | Per-byte extract + place + OR |

**Gotcha**: ctlz cascade direction matters. MSB→LSB with select-overwrite gives
the LAST set bit (wrong). LSB→MSB gives the HIGHEST set bit (correct for clz).
Same in reverse for cttz.

**Opcode audit results**: tested 30 Julia functions. 28 compile successfully.
3 failed before intrinsic expansion (ctpop, ctlz, cttz → now fixed).
Added freeze (identity), fptosi/fptoui, sitofp/uitofp, float type widths.
Remaining 2 blockers: float_div (extractvalue lowering, Bennett-dqc),
float_to_int (SoftFloat dispatch model, Bennett-777).

**LLVM opcode coverage (final audit)**:
- Tier 1: 100% (all integer/logic/control/aggregate/memory)
- Tier 2: switch, freeze, fptosi/sitofp/uitofp handled
- Intrinsics: 12 (umax/umin/smax/smin/abs/fshl/fshr/ctpop/ctlz/cttz/bitreverse/bswap)
- Float: add/sub/mul/neg via SoftFloat. div blocked (Bennett-dqc).
- 28/30 audit functions compile.

### SAT-based pebbling (Bennett-5i1)

Implemented Meuli 2019 SAT encoding with PicoSAT:
- Variables: p[v,i] = node v pebbled at step i
- Move clauses: (p[v,i] ⊕ p[v,i+1]) → ∧_u∈pred(v) (p[u,i] ∧ p[u,i+1])
- Cardinality: sequential counter encoding for ∑ p[v,i] ≤ P
- Iterative K search from 2N-1 upward

**Critical bug found**: cardinality auxiliary variables must be unique per time step.
All (K+1) calls to _add_at_most_k! were sharing the same variable range, causing
false UNSAT. Fix: offset = n_pebble_vars + i × aux_per_step.

| Chain | P (full) | P (reduced) | Steps (full) | Steps (reduced) |
|-------|----------|-------------|--------------|-----------------|
| N=3   | 3        | —           | 5            | —               |
| N=4   | 4        | 3           | 7            | 9               |
| N=5   | 5        | 4           | 9            | 9               |

Chain(4) P=3 matches Knill's F(4,3)=9 exactly. The SAT solver finds the
optimal schedule automatically.

**The 71K gate cost is dominated by control flow**, not arithmetic. The 3-node
tree has ~60 branch points (icmp + select for each ternary). Reducing this
requires branchless node selection (QRAM-style bucket brigade instead of MUX
chains) or specialized hardware for reversible pointer chasing.

### AG13 reversible heap operations (Bennett-e6k)

Implemented Axelsen/Glück 2013 EXCH-based heap operations:
- 3-cell heap packed in UInt64 (9 bits/cell: in_use + 4-bit left + 4-bit right)
- Stack-based free list (free_ptr in bits 27-29)
- cons and decons are exact inverses

| Operation | Gates | Description |
|-----------|-------|-------------|
| rev_cons | 59,066 | Allocate cell, store (a,b) pair |
| rev_car | 51,098 | Read left field of cell |
| rev_cdr | 51,090 | Read right field of cell |
| rev_decons | 52,196 | Deallocate cell, return to free list |

**Gate cost breakdown**: ~51K base cost is the variable-shift barrel shifter
for `(heap >> shift)` where shift = (idx-1)*9. Each variable-amount shift
on 64-bit = 6-stage barrel shifter ≈ 1,536 gates × ~30 shifts per function.
The bit manipulation (masking, OR-ing) is cheap; the pointer arithmetic is
expensive. This matches the tree observation: pointer chasing dominates.

### Complete reversible memory gate cost table

| Operation | Type | Gates | Per-element |
|-----------|------|-------|-------------|
| MUX get | Array N=4 | 394 | 99 |
| MUX get | Array N=8 | 746 | 93 |
| MUX EXCH | Array N=4 | 1,402 | 351 |
| Static EXCH | Array idx=0 | 442 | — |
| Tree lookup | BST 3 nodes | 1,292 | 431 |
| RB insert | Okasaki 3 nodes | 71,424 | 23,808 |
| Heap cons | AG13 3 cells | 59,066 | 19,689 |
| Heap car | AG13 3 cells | 51,098 | 17,033 |
| Heap cdr | AG13 3 cells | 51,090 | 17,030 |
| Heap decons | AG13 3 cells | 52,196 | 17,399 |

---

## 2026-04-10 — Complete session summary

### Issues closed this session

| Issue | Priority | What |
|-------|----------|------|
| Bennett-6lb | P1 | EAGER cleanup: `eager_bennett()`, `peak_live_wires()` |
| Bennett-282 | P1 | Reversible persistent memory: MUX EXCH + Okasaki RB tree |
| Bennett-e6k | P2 | AG13 reversible heap: cons/car/cdr/decons |
| Bennett-5i1 | P2 | SAT-based pebbling (Meuli 2019) with PicoSAT |

### New issues filed

| Issue | Priority | What |
|-------|----------|------|
| Bennett-dqc | P2 | soft_fdiv extractvalue lowering for Float64 division |
| Bennett-777 | P2 | Mixed-type Float64→Int compile path (fptosi dispatch) |

### LLVM opcode coverage — final state

**Handled opcodes (34 + 12 intrinsics):**

Arithmetic: add, sub, mul, udiv, sdiv, urem, srem
Bitwise: and, or, xor, shl, lshr, ashr
Comparison: icmp (eq, ne, ult, ugt, ule, uge, slt, sgt, sle, sge)
Control flow: br, switch, phi, select, ret, unreachable
Type conversion: sext, zext, trunc, freeze, fptosi, fptoui, sitofp, uitofp
Aggregates: extractvalue, insertvalue
Memory: getelementptr (const), load
Calls: registered callees + 12 intrinsics

**Intrinsics (12):** umax, umin, smax, smin, abs, fshl, fshr, ctpop, ctlz, cttz, bitreverse, bswap

**Skipped (by design):** store, alloca (reversible memory research)
**Not yet needed:** bitcast (LLVM optimizes away), fpext, fptrunc, frem, vector.reduce

**Audit: 28/30 functions compile** to verified reversible circuits:
abs, min, max, clamp, popcount, leading_zeros, trailing_zeros, count_zeros,
bitreverse, bswap, iseven, collatz_step, fibonacci, xor_swap, gcd_step,
sort2, hash_mix, reinterpret, flipsign, copysign, rotl, muladd,
widening_mul, 3-way branch, fizzbuzz, nested_select,
float_add/sub/mul/neg (via SoftFloat).

**2 remaining blockers:** float_div (Bennett-dqc), float_to_int (Bennett-777).

### New files this session

| File | Lines | What |
|------|-------|------|
| `src/eager.jl` | ~90 | EAGER cleanup: dead-end wire uncomputation |
| `src/sat_pebbling.jl` | ~170 | SAT-based pebbling with PicoSAT |
| `test/test_eager_bennett.jl` | ~100 | 971 tests: helpers + correctness + peak liveness |
| `test/test_switch.jl` | ~20 | Switch instruction tests |
| `test/test_rev_memory.jl` | ~180 | MUX EXCH + Okasaki RB tree + AG13 heap |
| `test/test_sat_pebbling.jl` | ~50 | SAT pebbling: chain, diamond, reduction |
| `test/test_intrinsics.jl` | ~50 | ctpop, ctlz, cttz, bitreverse, bswap |

### Key research findings

1. **Per-wire mod-path reversal is incorrect** at the gate level — only reverse
   gate-index order maintains the state invariant for Bennett uncomputation.

2. **MUX array EXCH beats persistent trees** for small N (1,402 vs 71,424 gates
   for N=4). Tree wins for dynamic-size collections.

3. **Persistence = reversibility**: each tree insert creates a new version;
   the old version is the ancilla for Bennett uncomputation.

4. **SAT pebbling matches Knill** for chains: chain(4) P=3 → 9 steps.
   Critical bug: cardinality auxiliary variables must be unique per time step.

5. **Variable-shift barrel shifter dominates** reversible heap cost (~51K of
   59K gates for cons). Pointer arithmetic is the bottleneck.

### Handoff for next session

**Priority work:**
1. Fix Bennett-dqc (soft_fdiv extractvalue) — likely needs multi-return handling in lower.jl
2. Fix Bennett-777 (Float64→Int dispatch) — needs new compile path for mixed types
3. Connect SAT pebbling to actual circuit optimization (generate optimized bennett from schedule)
4. Connect EAGER + wire reuse for actual ancilla reduction

**Commands:**
```bash
cd Bennett.jl
julia --project -e 'using Pkg; Pkg.test()'     # Full suite
bd ready                                        # Available issues
bd show Bennett-dqc                             # Float div bug
bd show Bennett-777                             # Float→Int bug
```

---

