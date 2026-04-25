## Session log — 2026-04-20 — Bennett-cc0.7 closed (SLP-vectorised IR support)

User plan (top of session): fix cc0.7 first as highest leverage per hour —
unblocks `optimize=true` across every gate-count we've measured (3-50× drop),
and is the cheapest of the five ir_extract gaps. Full suite GREEN post-fix,
all pre-fix gate-count baselines byte-identical.

### RED test + ground-truth

- `benchmark/cc07_repro_n16.jl` — N=16 linear_scan demo extracted from the
  sweep codegen. Parser-safe at N=16 (N=1000 blows Julia's parse stack).
- `test/test_cc07_repro.jl` — RED gate. Confirmed pre-fix:
  `Unsupported LLVM opcode: LLVMInsertElement in instruction:
  %0 = insertelement <8 x i8> poison, i8 %"seed::Int8", i64 0`.
- Full vectorised IR in `/tmp/cc07_n16_ir.ll`: 2 insertelement, 2 shufflevector,
  8 extractelement, 1 vector add `<8 x i8>`, 1 vector icmp `<8 x i8>`,
  1 bitcast `<8 x i1>` → `i8` (bit-pack).

### 3+1 protocol

- `docs/design/cc07_proposer_A.md` (1,235 lines, general-purpose subagent)
- `docs/design/cc07_proposer_B.md` (1,055 lines, general-purpose subagent)
- `docs/design/cc07_consensus.md` (orchestrator synthesis)

Both proposers converged on **scalarise at extractor boundary**: vector SSA
modelled as N per-lane IROperands in a side table; vector ops desugar into
N scalar IRInsts; insertelement / shufflevector are pure SSA plumbing
(emit nothing). Zero `lower.jl` touches.

### Empirical correction to both proposers

Both cited `freeze`'s `IRBinOp(:add, x, iconst(0), w)` as a "zero-gate
rename precedent". **Falsified**: empirical check showed `f(x) = x + Int8(0)`
compiles to 10 gates at i8 (2 NOT + 8 CNOT, ~W+2). Consensus accepted the
~W+2-gate cost per extractelement for MVP (8 extracts × ~10 = 80 gates at
i8, negligible vs ~5k total). True zero-cost "rename via names-table mutation"
deferred as a follow-up bead. This is the kind of "deep and interlocked"
LLVM-assumption gotcha CLAUDE.md §7 warns about.

### Shuffle-mask accessor

Consensus assumed `LLVMGetShuffleVectorMaskElement` (Proposer B). Grep of
`~/.julia/packages/LLVM/fEIbx/lib/*/libLLVM.jl` showed that symbol does NOT
exist. The real accessors are `LLVMGetNumMaskElements` + `LLVMGetMaskValue`
(Proposer A was right). Mask values: `Cint`, `-1` encodes poison.

### Implementation — src/ir_extract.jl

Added ~230 lines contained to `ir_extract.jl`; zero touches elsewhere.

- `_safe_is_vector_type(val)` — try/catch around `LLVM.value_type`.
- `_any_vector_operand(inst)` — try/catch-wrapped operand scan with a
  raw-C-API fallback (`LLVMGetNumOperands` / `LLVMGetOperand`) when
  LLVM.jl's iterator raises on unsupported value kinds. This was the
  load-bearing gotcha — the dispatch-guard probe iterating `LLVM.operands`
  tripped the pre-existing cc0.3 `LLVMGlobalAliasValueKind` path on
  call-instruction callees. Fix was strictly defensive: iterate via raw
  refs, skip operands the Julia wrapper can't materialise.
- `_vector_shape(val) -> (n_lanes, elem_width) | nothing`
- `_resolve_vec_lanes(val, lanes, names, n_expected)` — 4 paths:
  already-populated SSA, ConstantDataVector, ConstantAggregateZero,
  poison/undef (sentinel lane, crashes fail-loud if read).
- `_convert_vector_instruction(inst, names, lanes, counter)` — handles
  insertelement / shufflevector / extractelement / vector add-sub-mul-and-or-xor-shl-lshr-ashr /
  vector icmp / vector select (scalar-i1 or `<N x i1>` cond) / vector
  sext/zext/trunc / vector bitcast (same-shape identity + `<N x i1>` → `iN`
  bit-pack).
- `<N x i1>` → `iN` bitcast: emitted as `zext → shl → or` chain. Common
  after vector icmp that LLVM wants to reduce to a single scalar mask byte.
- Dispatcher gate at the top of `_convert_instruction` — single guard,
  byte-identical behaviour for scalar-only functions.

### Gate-count deltas (cc0.7 target: ls_demo_16)

| Build | Gates | Toffoli | Ancilla |
|---|---:|---:|---:|
| optimize=false (pre-fix workaround) | 22,902 | 5,250 | 6,958 |
| optimize=true (post-fix cc0.7) | **5,218** | **1,348** | **824** |
| Ratio | 4.4× fewer | 3.9× fewer | 8.4× fewer |

Within the bead-note predicted 3-50× range. Reduction driven by sroa +
mem2reg + instcombine + simplifycfg all running (previously all disabled
under `optimize=false`).

### Regression check — all baselines byte-identical

Full suite GREEN. Spot-checks vs 2026-04-17 WORKLOG numbers:

| Primitive | Pre-fix | Post-fix | Δ |
|---|---:|---:|---|
| soft_fptrunc | 36,474 | 36,474 | 0 |
| popcount32 standalone | 2,782 | 2,782 | 0 |
| HAMT demo (max_n=8) | 96,788 | 96,788 | 0 |
| CF demo (max_n=4) | 11,078 | 11,078 | 0 |
| CF+Feistel | 65,198 | 65,198 | 0 |

Zero-regression guarantee held by construction: the dispatch guard diverts
vector instructions before any scalar path changes. Functions with no
vector ops take the same codepath as pre-fix.

### Tests added

- `test/test_cc07_repro.jl` — N=16 RED → GREEN gate.
- `test/test_vector_ir.jl` — 3 focused micro-tests × ~8 inputs each:
  (1) splat + vector add + extract (insertelement + shufflevector + vadd + extract),
  (2) vector icmp + extract `<N x i1>` + bitcast-to-scalar bit-pack,
  (3) ConstantDataVector operand (distinct constant per lane).
- Both wired into `test/runtests.jl` before the T5 block.

### Follow-ups / optimizations deferred

1. Zero-gate extractelement: true rename via `names`-table mutation +
   `value_aliases::Dict{_LLVMRef, IROperand}` side table for constant-lane
   extracts. Would save ~10 gates per extract. Not urgent — the 3-50×
   `optimize=true` win swamps this cost.
2. Dynamic-index insertelement / extractelement: MUX tree. Fail-loud today;
   file bead if observed.
3. Vector phi / ret / load / store: not in cc0.7 fixture; fail-loud today.
4. Vector float ops: soft-float is per-scalar; vectorised soft-float is a
   separate milestone.
5. Vector-to-scalar bitcast for shapes other than `<N x i1> → iN`: fail-loud
   today; `<N x i8> → iN*8` would need a shift-and-or pack tree but is
   strictly additive.

### Sequence note (from user plan)

Remaining ir_extract gaps: cc0.3 (LLVMGlobalAlias — surface during iteration
was worked around defensively today but the underlying "extract const from
alias" path is still broken), cc0.5 (TLS/thread_ptr GEP), cc0.4 (constant-ptr
icmp), cc0.6 (error-report cleanup). Next up per user plan:
cc0.3 + cc0.5 as a paired PR; then cc0.4; then cc0.6.

---

