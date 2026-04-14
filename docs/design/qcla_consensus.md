# QCLA Design Consensus — Q1 (Bennett-cnyx)

Synthesized from `qcla_proposer_A.md` and `qcla_proposer_B.md`. Both
proposers converged on the paper's §4.1 algorithm; this doc pins the
concrete choices the implementer (Q3) will follow. Any deviation requires
re-opening Q1.

## Source

Draper, Kutin, Rains, Svore 2004 — *A Logarithmic-Depth Quantum
Carry-Lookahead Adder*, `docs/literature/arithmetic/draper-kutin-rains-svore-2004.pdf`
— §4.1 "Out-of-place addition" and §3 "Carry status".

## API

```julia
lower_add_qcla!(gates::Vector{ReversibleGate},
                wa::WireAllocator,
                a::Vector{Int},      # W-bit, LSB first; unchanged on exit
                b::Vector{Int},      # W-bit, LSB first; unchanged on exit
                W::Int
) -> Vector{Int}   # length W+1, LSB first; result[1..W] = (a+b) mod 2^W, result[W+1] = carry-out
```

Matches `lower_add!`'s shape but returns `W+1` wires (carry-out in the top
bit). All internal ancillae restored to zero on exit — the primitive is
self-contained and correct whether or not wrapped by Bennett's outer
construction.

Fail-fast on `W < 1`, `length(a) != W`, `length(b) != W`.

## Algorithm (5 phases, strictly sequential)

Paper-index (0-based) i ↔ Bennett-index (1-based) i+1. We emit in the
paper's canonical order (§4.1). No timeslice fusion; that is a future
depth-optimizer pass (see "Deferred" below).

**Phase 1 — Init G** (W Toffolis):
`Z[i+1] ⊕= a[i] · b[i]` for `i = 0..W-1` → in Bennett: `Toffoli(a[k], b[k], Z[k+1])` for `k = 1..W`.

**Phase 2 — Init P** (W−1 CNOTs):
`b[i] ⊕= a[i]` for `i = 1..W-1` → `CNOT(a[k], b[k])` for `k = 2..W`.
After this phase `b[k] = p[k-1, k]` for `k ≥ 2`; `b[1]` still holds `b_0`.

**Phase 3 — Carry tree** (paper §3):
- **3a P-rounds** for `t = 1..T-1`, `m = 1..⌊W/2^t⌋-1`:
  `P_t[m] ⊕= P_{t-1}[2m] · P_{t-1}[2m+1]`.
  `P_0[k]` aliases `b[k+1]`; `P_t` for `t ≥ 1` lives in `Xflat`.
  Count: `W - w(W) - ⌊log W⌋` Toffolis.
- **3b G-rounds** for `t = 1..T`, `m = 0..⌊W/2^t⌋-1`:
  `G[2^t m + 2^t] ⊕= G[2^t m + 2^{t-1}] · P_{t-1}[2m+1]`.
  `G[j]` aliases `Z[j+1]`. Count: `W - w(W)`.
- **3c C-rounds** for `t = ⌊log(2W/3)⌋..1`, `m = 1..⌊(W - 2^{t-1})/2^t⌋`:
  `G[2^t m + 2^{t-1}] ⊕= G[2^t m] · P_{t-1}[2m]`. Count: `W - ⌊log W⌋ - 1`.
- **3d P⁻¹-rounds**: re-emit 3a's Toffolis in reverse (t, then m) —
  zeroes `Xflat`. Count: `W - w(W) - ⌊log W⌋`.

**Phase 4 — Form sum bits** (W CNOTs):
`Z[k] ⊕= b[k]` for `k = 1..W`. After: `Z[1] = b_0`; `Z[k] = s_{k-1}` for `k ≥ 2`.

**Phase 5 — Restore b, finalize s_0** (W CNOTs):
`CNOT(a[1], Z[1])` turns `Z[1]` into `a_0 ⊕ b_0 = s_0`.
`CNOT(a[k], b[k])` for `k = 2..W` undoes phase 2 and restores `b`.

## Wire layout

| Role              | Wires                         | Allocation                         | Exit state                   |
|-------------------|-------------------------------|------------------------------------|------------------------------|
| `a` input         | `W`                           | caller                             | unchanged                    |
| `b` input         | `W`                           | caller                             | unchanged (restored phase 5) |
| `Z` output        | `W + 1`                       | `allocate!(wa, W+1)`               | `[s_0, s_1, …, s_{W-1}, c_W]`|
| `Xflat` ancilla   | `W − w(W) − ⌊log₂ W⌋`         | `allocate!(wa, N_anc)` if `W ≥ 4`  | all zero                     |

`Xflat` stores `P_t` levels contiguously in increasing `t` order, with
per-level block length `⌊W/2^t⌋ − 1`. A helper
`_qcla_level_offsets(W, T)` returns the 0-based block starts; `Ptm(t, m) =
Xflat[_qcla_level_offsets(W, T)[t] + m]` for `t ≥ 1`. For `t = 0` the
caller reads `b[m+1]` directly.

Accept proposer B's flat-block layout over proposer A's
`Dict{Tuple{Int,Int},Int}` — cleaner and lower overhead. Proposer A's
dictionary is semantically equivalent but adds allocator churn.

## Small-W fallback

`W ≤ 3` has no `P_t` for `t ≥ 1` (tree is empty). The paper's formulas
overcount at tiny W; ripple-carry is already optimal and can produce the
W+1-bit answer directly. Accept proposer B's `_lower_add_small_outplace!`
which allocates `W+1` output wires plus `W+1` carry wires and emits
plain ripple across all `W+1` lanes (with synthetic zero padding for
`a[W+1] = b[W+1] = 0`). Returns the same-shape vector (length `W+1`) so
the dispatcher downstream sees one uniform contract.

## Cost formulas (numeric)

Both proposers independently verified:

| Metric         | Formula                              | W=4 | W=8 | W=16 | W=32 | W=64 |
|----------------|--------------------------------------|----:|----:|-----:|-----:|-----:|
| Toffoli        | `5W − 3w(W) − 3⌊log₂ W⌋ − 1`         | 10  | 27  | 64   | 141  | 298  |
| Toffoli-depth  | `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4`         | 6   | 8   | 10   | 12   | 14   |
| CNOT           | `3W − 1`                             | 11  | 23  | 47   | 95   | 191  |
| Total depth    | `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7`         | 9   | 11  | 13   | 15   | 17   |
| Ancilla        | `W − w(W) − ⌊log₂ W⌋`                | 1   | 4   | 11   | 26   | 57   |

**Important caveat from proposer A**: QCLA has *more* Toffolis than
ripple-carry (ripple = `2(W-1)` Toffolis). The win is **depth**: ripple
is `O(W)`, QCLA is `O(log W)`. Crossover for depth is ~W=8. This
motivates the dispatcher's rule (P2): `:qcla` when depth matters,
`:ripple`/`:cuccaro` otherwise. Never silently route `:auto` to QCLA when
gate count is the cost function.

## Invariants (principle 4 — exhaustive verification targets)

1. `a` and `b` are byte-for-byte identical before and after the call.
2. `Xflat` is all-zero on exit (P⁻¹-rounds are a mirror of P-rounds).
3. `Z[1..W]` = `(a + b) mod 2^W`; `Z[W+1]` = carry-out.
4. Ordering: phase 1 must precede phase 2 because phase 1 reads original
   `b`; if phase 2 ran first, `Z[k+1]` would be written as
   `a_{k-1} · (a_{k-1} ⊕ b_{k-1}) = a_{k-1} · ¬b_{k-1}` instead of
   `a_{k-1} · b_{k-1}`. This was explicitly called out by proposer A
   and is a common-case bug to guard against.

## Test plan (Q2 RED target)

Unit-level in `test/test_qcla.jl`:

1. **Fallback correctness** for `W ∈ {1, 2, 3}`: exhaustive 2^(2W)
   enumeration; `Z[1..W]` = `(a+b) mod 2^W`; `Z[W+1]` = carry-out.
2. **Exhaustive correctness** for `W = 4`: all 256 `(a, b)` pairs; every
   `Z` bit checked bit-by-bit against reference.
3. **Exhaustive correctness** for `W = 8`: all 65,536 pairs.
4. **Sampled correctness** for `W = 16, 32`: 10k random pairs + edge
   cases (0, max, `0x55…`, `0xAA…`, `a=b`, `a+b` = 2^W boundary).
5. **Gate-count pins** (regression per principle 6): exact Toffoli, CNOT,
   ancilla, total-depth values at `W = 4, 8, 16, 32, 64` matching the
   table above.
6. **Toffoli-depth pin** matching `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4` via
   `toffoli_depth()` (M1).
7. **Ancilla-zero check**: after the gate list runs against a random
   bit-vector and then runs in reverse, the X-block wires are all zero.
8. **Fallback vs QCLA equivalence** at `W = 4`: both paths produce the
   same `(a + b)` for every input (safety net against a buggy QCLA
   emitting valid-but-wrong arithmetic).

Must FAIL on `main` (QCLA doesn't exist yet).

## Implementation file

`src/qcla.jl`. Include from `src/Bennett.jl` after `adder.jl`. Export
`lower_add_qcla!` so `reversible_compile(..., add=:qcla)` (D1) can reach
it. No changes to `lower.jl` in this issue — dispatcher wiring lives in D1.

## Deferred

- **Timeslice fusion** for tighter wall-clock depth. The paper shows
  P/G/C rounds can overlap within a single O(log W) depth. Bennett.jl
  has no scheduler; a future pass can re-order commuting gates. Current
  emission order is strictly sequential per-phase; measured depth is
  `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7` as pinned above.
- **In-place variant** (paper §4.2). Adds ~14 gates of overhead
  (negate → reverse → negate); separate primitive `lower_add_qcla_inplace!`
  if ever needed, filed as a follow-up when the dispatcher is ready.
- **Non-power-of-2 width verification**: the formulas hold for all W ≥ 4
  but some of the floor-division boundaries get subtle. Test plan
  covers W = 5, 6, 7 explicitly in sampled cases to flush any bugs.

## Why both proposers converged

Both independently picked: (a) out-of-place, (b) W+1 output width, (c)
paper's §4.1 sequential phase emission, (d) fallback at small W, (e)
identical Toffoli/CNOT formulas. Divergences were purely cosmetic (Dict
vs flat block for `Xflat` layout; which helper owns the small-W path).
Consensus chooses proposer B's flat block + custom `_lower_add_small_outplace!`
for cleaner structure.
