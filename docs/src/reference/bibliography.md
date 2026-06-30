# Bibliography

*A lookup table of the papers Bennett.jl implements: each entry gives the
canonical reference, its one-line contribution, and the source file(s) where
it lives. For the longer annotated survey (verified claims, cross-citations,
the memory-model corpus) see [`docs/literature/SURVEY.md`](../../literature/SURVEY.md).
The PDFs themselves are checked into [`docs/literature/`](../../literature/),
grouped under `arithmetic/`, `memory/`, `multiplication/`, and the pebbling
subfolders.*

## Quick index

| Reference | Identifier | Contribution | Used in |
|---|---|---|---|
| Bennett 1973 | DOI [10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525) | The forward + copy-out + uncompute construction the whole project is named after | `src/bennett_transform.jl` |
| Bennett 1989 | DOI [10.1137/0218053](https://doi.org/10.1137/0218053) | Time/space trade-offs; the pebble game on computation DAGs | conceptual — no strategy implements it directly |
| Knill 1995 | [arXiv:math/9508218](https://arxiv.org/abs/math/9508218) | Exact recursion for the time-optimal pebble game at fixed space | `src/pebble/pebbling.jl` |
| PRS15 (Parent–Roetteler–Svore 2015) | [arXiv:1510.00377](https://arxiv.org/abs/1510.00377) | EAGER / incremental cleanup; ~4× space cut at equal gate count | `src/pebble/value_eager.jl`, `src/pebble/eager.jl` |
| Cuccaro et al. 2004 | [arXiv:quant-ph/0410184](https://arxiv.org/abs/quant-ph/0410184) | In-place ripple-carry adder with a single ancilla (MAJ / UMA) | `src/adder.jl` |
| Draper–Kutin–Rains–Svore 2004 | [arXiv:quant-ph/0406142](https://arxiv.org/abs/quant-ph/0406142) | Logarithmic-Toffoli-depth carry-lookahead adder | `src/qcla.jl` |
| Sun–Borissov 2026 | [arXiv:2604.09847](https://arxiv.org/abs/2604.09847) | Polylogarithmic-depth multiplier (fast-copy + partial products + adder tree) | `src/mul_qcla_tree.jl`, `src/fast_copy.jl`, `src/partial_products.jl`, `src/parallel_adder_tree.jl` |
| Babbush–Gidney et al. 2018 | [arXiv:1805.03662](https://arxiv.org/abs/1805.03662) | QROM table lookup with linear (W-independent) T complexity | `src/qrom.jl`, `src/tabulate.jl` |
| Luby–Rackoff 1988 | SIAM J. Comput. 17(2) | Feistel rounds turn a PRF into a bijection — the reversible hash core | `src/feistel.jl`, `src/persistent/hashcons_feistel.jl` |
| Moses–Churavy 2020 (Enzyme) | [arXiv:2010.01709](https://arxiv.org/abs/2010.01709) | LLVM-level AD; shadow-memory and reverse-pass patterns we adapt | `src/shadow_memory.jl` |

The per-paper entries below add the detail that does not fit a table cell.

## Foundations

### Bennett 1973 — *Logical Reversibility of Computation*

- Charles H. Bennett, *IBM Journal of Research and Development* 17(6):525–532, 1973. DOI [10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525).
- **Contribution.** Any computation can be made reversible at the cost of extra
  auxiliary memory: run it forward while recording intermediate results, copy
  out the answer, then run the forward computation in reverse to erase the
  record. All ancillae return to zero.
- **Where.** `src/bennett_transform.jl` — `_bennett_default(lr)`, reached via
  `DefaultStrategy`. The citation block is at `src/bennett_transform.jl:240`.
  This is pipeline stage 3 (extract → lower → **bennett** → simulate).

```julia
julia> using Bennett

julia> c = reversible_compile(x -> x + Int8(1), Int8);   # default == add=:ripple, fold_constants=true

julia> gate_count(c)            # gate_count returns a NamedTuple, not an Int
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> ancilla_count(c), toffoli_depth(c), verify_reversibility(c)
(25, 12, true)
```

The architecture page [`../explanation/architecture.md`](../explanation/architecture.md) and the
explanation [`../explanation/bennett_construction.md`](../explanation/bennett_construction.md)
walk through the construction itself. Note: the root
[`README.md`](../../../README.md) historically hyperlinked "Bennett's 1973
construction" to the 1989 DOI — the correct DOI for the *1973* paper is
`10.1147/rd.176.0525`.

### Bennett 1989 — *Time/Space Trade-Offs for Reversible Computation*

- Charles H. Bennett, *SIAM Journal on Computing* 18(4):766–776, 1989. DOI [10.1137/0218053](https://doi.org/10.1137/0218053).
- **Contribution.** A reversible machine can simulate an irreversible one in
  time `O(T^{1+ε})` and space `O(S·log T)`, via the pebble game on the
  computation DAG.
- **Where.** Listed in the project references and the survey, but **no strategy
  implements the 1989 recursive construction directly.** The space-time
  `BennettStrategy` variants implement Knill 1995's *analysis* of the same
  pebble game (see below). Do not reuse this DOI for the 1973 construction.

## Space–time strategies (pebbling and cleanup)

### Knill 1995 — *An analysis of Bennett's pebble game*

- E. Knill, [arXiv:math/9508218](https://arxiv.org/abs/math/9508218), 1995.
- **Contribution.** Theorem 2.1 gives the exact recursion for the time-optimal
  pebbling at a fixed space bound, `F(n,S) = min_m [ F(m,S) + F(m,S−1) +
  F(n−m,S−1) ]`; Theorem 2.3 gives `F(n,S) < ∞ ⇔ n ≤ 2^{S−1}`, hence the
  minimum-pebble count `1 + ⌈log₂ n⌉`.
- **Where.** `src/pebble/pebbling.jl` — `knill_pebble_cost`, `min_pebbles`,
  `knill_split_point`, `pebble_tradeoff`, and `_pebbled_bennett_impl` reached
  via `PebbledStrategy(max_pebbles)`. `PebbledGroupStrategy` adds wire reuse on
  top (`src/pebble/pebbled_groups.jl`).
- **Note.** The earlier "Meuli 2019 SAT pebbling" path was removed — `sat_pebbling.jl`
  and the PicoSAT dependency are deleted. `PebbledGroupStrategy` is Knill 1995 +
  PRS15 ancilla reuse, not SAT-based.

### PRS15 — Parent, Roetteler, Svore 2015 — *Reversible circuit compilation with space constraints*

- [arXiv:1510.00377](https://arxiv.org/abs/1510.00377).
- **Contribution.** The REVS compiler with a Mutable Data Dependency graph and
  two cleanup strategies — EAGER (uncompute as soon as dependents are done,
  Algorithm 2) and incremental checkpointing (Algorithm 3) — reaching ~4×
  space reduction over full Bennett at the same gate count.
- **Where.**
  - `src/pebble/value_eager.jl` — `_value_eager_bennett_impl` (`ValueEagerStrategy`)
    is the actual PRS15 Algorithm 2: group/value-level EAGER plus a Kahn
    reverse-topological uncompute over the SSA `GateGroup` DAG.
  - `src/pebble/eager.jl` — `_eager_bennett_impl` (`EagerStrategy`) is gate-level
    **dead-end** cleanup only (uncompute wires never used as a control). The
    file's header docstring says "Algorithm 2", but the in-file note clarifies
    wire-level EAGER fails at gate granularity; `ValueEagerStrategy` is the
    real one.
  - Checkpoint/group strategies (`CheckpointStrategy`, `PebbledGroupStrategy`)
    in `src/pebble/pebbled_groups.jl` borrow the PRS15 ancilla-heap idea.

All six strategies honor the self-reversing fast path and refuse branching
CFGs (falling back to `_bennett_default`). See [`../reference/api.md`](../reference/api.md) for the
`bennett(lr; strategy=...)` surface and the five legacy aliases.

## Arithmetic primitives

### Cuccaro, Draper, Kutin, Moulton 2004 — ripple-carry adder

- [arXiv:quant-ph/0410184](https://arxiv.org/abs/quant-ph/0410184), Figure 5.
- **Contribution.** In-place ripple-carry addition `(a, b, 0) → (a, a+b, 0)`
  using only **one** ancilla, via MAJ (majority) gates rippling up and UMA
  (unmajority-and-add) gates rippling back down.
- **Where.** `src/adder.jl` — `lower_add_cuccaro!`, selected by `add=:cuccaro`.
  With the §3.5 high-bit optimisation (Bennett-gsxe) the mod-`2^W` variant costs
  `2W−3` Toffoli, `4W−2` CNOT, `0` NOT (total `6W−5`), pinned by
  `test/test_op6a_cuccaro_gate_count.jl`. Note `add=:auto` resolves to
  `:ripple`, not `:cuccaro`.

### Draper, Kutin, Rains, Svore 2004 — carry-lookahead adder

- [arXiv:quant-ph/0406142](https://arxiv.org/abs/quant-ph/0406142), §4.1, Theorem 1.
- **Contribution.** An out-of-place adder with `O(log W)` Toffoli-depth — the
  win is depth, not gate count (it has more Toffolis than ripple-carry at every
  width).
- **Where.** `src/qcla.jl` — `lower_add_qcla!`, selected by `add=:qcla`. The
  §4.1 cost formulas (`5W − 3·w(W) − 3·⌊log₂W⌋ − 1` Toffoli, etc.) are
  regression-tested at `W ∈ {4,8,16,32,64}` in `test/test_qcla.jl`.

```julia
julia> verify_reversibility(reversible_compile(x -> x + Int8(7), Int8; add=:qcla))
true
```

### Sun–Borissov 2026 — polylogarithmic-depth multiplier

- [arXiv:2604.09847](https://arxiv.org/abs/2604.09847).
- **Contribution.** A `2W`-bit-product multiplier with `O(log²n)` Toffoli-depth,
  assembled from a doubling broadcast, all `W²` partial products, and a
  self-cleaning binary tree of carry-lookahead adders. The primitive is
  self-reversing — it needs no outer Bennett wrap.
- **Where.**
  - `src/mul_qcla_tree.jl` — `lower_mul_qcla_tree!`, selected by `mul=:qcla_tree`
    (and by `mul=:auto` when `target=:depth`).
  - `src/fast_copy.jl` — Algorithm 1 (`emit_fast_copy!`): `(n−1)·W` CNOTs, zero
    Toffolis, depth `⌈log₂ n⌉`.
  - `src/partial_products.jl` — §II.C building blocks (`emit_conditional_copy!`,
    `emit_partial_products!`).
  - `src/parallel_adder_tree.jl` — §II.D self-cleaning adder tree.
- The `mul=:shift_add` schoolbook multiplier (`src/multiplier.jl`) is the
  gate-count default; `mul=:karatsuba` was **removed** (2026-04-27) and now
  throws.

```julia
julia> toffoli_depth(reversible_compile((x, y) -> x * y, Int32, Int32))                    # default: shift_add
180

julia> toffoli_depth(reversible_compile((x, y) -> x * y, Int32, Int32; mul=:qcla_tree))    # Sun–Borissov tree
56
```

## Memory and table lookup

### Babbush, Gidney, Berry, Wiebe, McClean, Paler, Fowler, Neven 2018 — QROM

- *Encoding Electronic Spectra in Quantum Circuits with Linear T Complexity*,
  [arXiv:1805.03662](https://arxiv.org/abs/1805.03662) v2, §III.A (unary
  iteration), §III.C (QROM).
- **Contribution.** Read-only table lookup `(idx, 0^W) → (idx, table[idx])`
  built from a binary decision tree of Toffolis: `2(L−1)` Toffoli and
  `O(L·W)` CNOT for `L` entries, with a T-count of `4(L−1)` that is
  **independent of the word width W**.
- **Where.** `src/qrom.jl` — `emit_qrom!`, auto-dispatched by
  `lower_var_gep!` (`src/lowering/aggregate.jl`) when the GEP base is a
  compile-time-constant global table. `src/tabulate.jl` evaluates `f` on all
  `2^W` inputs and emits the result as a QROM lookup.

```julia
julia> sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1];

julia> gate_count(reversible_compile(sbox, UInt8))
(total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

### Luby, Rackoff 1988 — Feistel permutations

- *How to Construct Pseudorandom Permutations from Pseudorandom Functions*,
  *SIAM Journal on Computing* 17(2), 1988.
- **Contribution.** A few Feistel rounds `(L, R) ← (R, L ⊕ F(R))` turn a
  pseudorandom *function* into a pseudorandom *permutation* — i.e. a bijection,
  which is exactly what a reversible circuit needs from a hash.
- **Where.** `src/feistel.jl` — `emit_feistel!` (default 4 rounds, cost ~`4W`
  Toffoli), used as the reversible hash core for hash-consing in
  `src/persistent/hashcons_feistel.jl`. Note `emit_feistel!` is **never**
  auto-dispatched by the lowerer — it is a building block invoked explicitly.

### Moses, Churavy 2020 — Enzyme

- *Instead of Rewriting Foreign Code for Machine Learning, Automatically
  Synthesize Fast Gradients*, [arXiv:2010.01709](https://arxiv.org/abs/2010.01709).
- **Contribution.** LLVM-level automatic differentiation: activity analysis,
  a forward pass mirrored by an instruction-inverting reverse pass, a
  tape/cache for forward values, and **shadow memory** — a parallel allocation
  paralleling each active pointer.
- **Where.** `src/shadow_memory.jl` adapts the shadow-memory pattern to the
  reversibility setting: instead of accumulating derivatives, it checkpoints
  the primal's previous value onto a tape slot and restores it on Bennett's
  reverse pass. Cost is `3W` CNOT per store, `W` CNOT per load, zero Toffolis —
  the universal fallback when MUX-exchange, QROM, linear-scan, or Feistel
  storage do not fit. The reverse-pass / activity-analysis ideas more broadly
  parallel Bennett uncomputation and constant-wire elimination.

## See also

- [`../reference/api.md`](../reference/api.md) — the `reversible_compile` / `bennett` / metrics surface.
- [`../explanation/architecture.md`](../explanation/architecture.md) — the four-stage pipeline.
- [`../explanation/bennett_construction.md`](../explanation/bennett_construction.md) — why the 1973 construction is correct.
- [`docs/literature/SURVEY.md`](../../literature/SURVEY.md) and
  [`docs/literature/memory/COMPLEMENTARY_SURVEY.md`](../../literature/memory/COMPLEMENTARY_SURVEY.md) —
  the annotated survey, including the functional-data-structure corpus (Okasaki
  1999, Bagwell 2001 HAMT, Conchon–Filliâtre 2007) behind the persistent-memory
  workstream.
```