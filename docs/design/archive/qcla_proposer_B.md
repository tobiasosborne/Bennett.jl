# QCLA Primitive for Bennett.jl — Proposer B Design

Independent design for `lower_add_qcla!`, the n-bit out-of-place quantum
carry-lookahead adder based on Draper, Kutin, Rains, and Svore (2004),
*A Logarithmic-Depth Quantum Carry-Lookahead Adder* (arXiv:quant-ph/0406142).

All emitted gates are NOT / CNOT / Toffoli. The construction achieves
`O(log W)` Toffoli-depth while adding only linearly many ancillae,
which is why we are pulling it into the compiler as an alternative to
the ripple-carry `lower_add!` and the space-thrifty `lower_add_cuccaro!`.

---

## 1. Algorithm shape — out-of-place, self-uncomputing

**Shape chosen: out-of-place, self-contained.** The function consumes
two W-bit operand registers `a, b` (unchanged) and returns a freshly
allocated (W+1)-bit sum register. All scratch ancillae are allocated,
used, and restored to zero **inside** `lower_add_qcla!` itself.

Why this shape:

1. **Matches the existing `lower_add!` API.** `lower_add!` returns a
   newly allocated `W`-bit result register and leaves its carry
   ancillae dirty (Bennett's outer reverse pass cleans them). However,
   for QCLA the tree ancillae carry values that need careful inversion
   anyway (P^{-1} rounds). Doing the full paper construction
   **internally** is not significantly more expensive than the "dirty"
   variant *and* produces a cleanly reusable primitive that is correct
   whether or not it is wrapped by Bennett. Ancilla hygiene is checked
   by the simulator regardless, so a self-contained adder is easier to
   unit-test in isolation. (CLAUDE.md §4: exhaustive verification
   requires ancilla return-to-zero — self-contained QCLA satisfies it
   without relying on the outer Bennett wrapper.)

2. **Adds the overflow bit.** The paper's out-of-place adder produces
   `W+1` bits (`Z[0..W]`), matching an integer-sum semantics. We will
   truncate to `W` when the caller asks for mod-2^W add, but we build
   on top of the full-width version. (Caller layer — `lower.jl` — is
   free to discard `result[W+1]` when it only wants `a + b mod 2^W`.
   Truncation does not save gates in this out-of-place variant.)

3. **Bennett-friendly.** Self-contained means the **forward pass has
   zero ancilla residue** other than `result`. When Bennett wraps
   `lr.gates` with a reverse pass, it simply toggles `result` back to
   0 along with everything else — no surprises, no interaction with
   phi resolution or liveness analysis.

4. **In-place is a separate function.** The paper's in-place QCLA
   (§4.2) is ~2x more gates and has a trickier sequencing (it negates
   `b`, reverses the adder, re-negates). That belongs in a future
   `lower_add_qcla_inplace!` built by composing `lower_add_qcla!` with
   negation, not in this first primitive.

The forward pass emits five phases, in order, with no gate reordering
across phases:

  1. **Init g:**   `Z[i+1] ⊕= a[i] AND b[i]` for `0 ≤ i < W`
                   (W Toffoli gates; populates base-level G array).
  2. **Init p:**   `b[i] ⊕= a[i]` for `1 ≤ i < W`
                   (W−1 CNOT gates; rewrites `b` into the propagate array.
                   Bit 0 of `b` remains `b_0` — it is also `s_0` once
                   combined with `a_0`).
  3. **Carry tree:** Run the paper's §3 P-rounds, G-rounds, C-rounds,
                     P^{-1}-rounds on `Z[1..W]` (which holds base G) and
                     `b[0..W-1]` (which now holds base P), using X ancillae.
                     On exit: `Z[i] = c_i` for `1 ≤ i ≤ W`, X back to 0.
  4. **Form sum bits:** `Z[i] ⊕= b[i]` for `0 ≤ i < W`
                        (W CNOT gates; for `i ≥ 1`: `Z[i] = c_i ⊕ p_i = s_i`.
                        For `i = 0`: `Z[0] = 0 ⊕ b_0 = b_0`).
  5. **Restore b, finalize s_0:** `Z[0] ⊕= a[0]` (1 CNOT; makes
                                  `Z[0] = a_0 ⊕ b_0 = s_0`).
                                  `b[i] ⊕= a[i]` for `1 ≤ i < W`
                                  (W−1 CNOT; undoes phase 2, restoring b).

At the end: `Z[0..W]` holds the (W+1)-bit sum; `a` and `b` unchanged;
`X` ancillae zero; `Z[W]` is the carry-out (MSB of the sum).

---

## 2. Wire layout

All indices below are **1-based Julia wire indices**, with **bit 0 at
position 1** (LSB-first) to match `lower_add!`'s convention.

| Register        | Count   | Allocation order                             | Role                                                                                    |
|-----------------|---------|----------------------------------------------|-----------------------------------------------------------------------------------------|
| `a[1..W]`       | W       | caller-supplied                              | input, unchanged. `a[i]` holds `a_{i-1}` in paper's notation.                            |
| `b[1..W]`       | W       | caller-supplied                              | input, temporarily overwritten with propagate array, restored on exit.                  |
| `Z[1..W+1]`     | W+1     | 1st `allocate!(wa, W+1)`                     | output sum register. `Z[1]` = s_0; `Z[W+1]` = carry-out.                                |
| `Xflat`         | `W − w(W) − ⌊log₂ W⌋`  (see formula below) | 2nd `allocate!(wa, N_anc)` | all tree-level ancillae (P_1, P_2, …, P_{T-1}), concatenated. |

Within `Xflat`, P-level blocks are laid out contiguously in order of
increasing level `t`, each block of length `⌊W/2^t⌋ − 1`:

```
Xflat = [ P_1[1], P_1[2], …, P_1[⌊W/2⌋ − 1],
          P_2[1], …,           P_2[⌊W/4⌋ − 1],
          ⋮
          P_{T−1}[1], …,       P_{T−1}[⌊W/2^{T−1}⌋ − 1] ]
```

where `T = ⌊log₂ W⌋` (the highest P level is `T − 1`; we never need
`P_T` because P-round T would have `⌊W/2^T⌋ = 1 < 2` slots).

Ancilla count matches the paper's closed form:

```
N_anc = sum_{t=1}^{T-1} (⌊W/2^t⌋ − 1)
      = (W − w(W) − T)                     # by Eq (1): n − w(n) = Σ⌊n/2^i⌋
      = W − w(W) − ⌊log₂ W⌋
```

A tiny helper `_qcla_ancilla_offset(W, t)` (file-local) maps `(t, m)`
to the index inside `Xflat`:

```julia
function _qcla_p_index(W::Int, t::Int, m::Int)
    @assert 1 <= t <= floor(Int, log2(W)) - 1 "P_t index out of range"
    @assert 1 <= m < W >> t                    "P_t[m] out of range"
    off = 0
    for s in 1:(t-1)
        off += (W >> s) - 1
    end
    return off + m   # 1-based position inside Xflat
end
```

(Implementation note: computing this at emission time is O(log W) per
call, O(W log W) total — trivial next to the gate count.)

Nothing is stored for `P_0` (that lives in `b`) or for `G` (lives in
`Z[2..W+1]`, since `Z[i+1]` holds `g[i-1,i]` after phase 1, re-used
through the C-rounds as `g[0, i]`). `Z[1]` holds zero throughout phases
1–3 and becomes `s_0` in phases 4–5. `Z[W+1]` holds `g[W-1, W]` at
base, then gets upgraded to `g[0, W] = c_W = s_W` (carry-out) over the
tree.

### Allocator usage

Exactly **two** `allocate!` calls inside `lower_add_qcla!`:

1. `Z = allocate!(wa, W + 1)` — the output register.
2. `Xflat = allocate!(wa, N_anc)` — all P-level ancillae, only if
   `T ≥ 2` (i.e. `W ≥ 4`). For smaller W, `Xflat` is empty and can be
   skipped.

No further allocations. After the forward pass all of `Xflat` is back
to zero and can be `free!`'d by the caller if desired (though current
callers of `lower_add!` don't bother, so `lower_add_qcla!` won't
either, to stay API-symmetric).

---

## 3. Julia-style pseudocode

```julia
"""
QCLA out-of-place adder: (a, b) → (a, b, Z) with Z = a + b  (W+1 bits).

From Draper–Kutin–Rains–Svore 2004, §4.1 ("Addition out of place").
Computes carries via a binary P/G tree (§3) yielding O(log W) Toffoli
depth instead of O(W) for the ripple-carry adder.

Input:  a[1..W], b[1..W]  (both unchanged on exit)
Output: Z[1..W+1] returned, Z[1]=s_0 … Z[W+1]=s_W=carry-out
Ancillae: N = W − w(W) − ⌊log₂ W⌋, all restored to zero on exit.

Gate counts for W ≥ 4 (from paper Table 2, out-of-place + in Z):
  Toffoli  : 5W − 3 w(W) − 3 ⌊log₂ W⌋ − 1
  CNOT     : 3W − 1
  Toffoli-depth : ⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4
  Total depth   : ⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7

For W ≤ 3 the tree is empty; we fall back to `lower_add!` (ripple-carry).
"""
function lower_add_qcla!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                         a::Vector{Int}, b::Vector{Int}, W::Int)
    # ------- fail-fast guards -------
    W == length(a) || error("QCLA: a has $(length(a)) wires, expected $W")
    W == length(b) || error("QCLA: b has $(length(b)) wires, expected $W")
    W >= 1         || error("QCLA: W must be ≥ 1, got $W")

    # Small cases: QCLA has no tree when W ≤ 3 (T = ⌊log₂ W⌋ ≤ 1 ⇒ no P-rounds).
    # We could still emit just init-g + final-CNOT, but for W ≤ 3 the
    # paper's depth formula overcounts anyway (see paper page 7 footnote),
    # and ripple-carry is already optimal. Delegate for clarity.
    if W <= 3
        # lower_add! returns W bits (mod 2^W). For QCLA parity we want W+1 bits.
        # Implement a small W+1-bit ripple by hand:
        return _lower_add_small_outplace!(gates, wa, a, b, W)
    end

    T = floor(Int, log2(W))           # highest P level used = T - 1
    N_anc = W - _popcount(W) - T      # paper's formula

    # ------- allocate output Z (W+1 bits) and flat ancilla block --------
    Z = allocate!(wa, W + 1)
    Xflat = allocate!(wa, N_anc)

    # Index helper captured in closure (avoids recomputation of offsets).
    p_offsets = _qcla_level_offsets(W, T)   # p_offsets[t] = 0-based start of P_t block in Xflat
    Ptm(t, m) = Xflat[p_offsets[t] + m]     # P_t[m], 1-based wire index

    # ===================================================================
    # PHASE 1: Init G.   Z[i+1] ⊕= a[i] b[i]   for 0 ≤ i < W
    # Paper-index: populates g[i, i+1] at location Z[i+1].
    # Julia-index: Z[k+1] ⊕= a[k] AND b[k]   for k = 1..W  (k = i+1)
    # After: Z[2..W+1] holds the base-level G array.
    # ===================================================================
    for k in 1:W
        push!(gates, ToffoliGate(a[k], b[k], Z[k + 1]))
    end

    # ===================================================================
    # PHASE 2: Init P.   b[i] ⊕= a[i]   for 1 ≤ i < W
    # Julia-index: for k = 2..W,  b[k] ⊕= a[k]
    # After: b[k] = p[k-1, k] for k ≥ 2.  b[1] is still b_0.
    # ===================================================================
    for k in 2:W
        push!(gates, CNOTGate(a[k], b[k]))
    end

    # ===================================================================
    # PHASE 3: Carry tree (paper §3 on Z[2..W+1] and b[1..W]).
    #
    # Convention for this phase:
    #   - "Paper bit position" i  ∈ {0..W−1}  ↔  Julia wire b[i+1]  for P_0
    #   - "Paper G[j]"            j ∈ {1..W}  ↔  Julia wire Z[j+1]
    #     (so G[j] = g[j−1, j] initially, later g[0, j] = c_j)
    #
    # The tree has four sub-rounds interleaved (paper's timeslice diagram):
    #   3a) P-rounds      (build P_t)
    #   3b) G-rounds      (build block-G)
    #   3c) C-rounds      (broadcast carries from position 0)
    #   3d) P^{-1}-rounds (restore Xflat to zero)
    #
    # Ordering: we emit them in the paper's canonical sequential order
    # first — correctness is phase-ordering-independent; timeslice fusion
    # is an optimisation we leave to a later pass (depth is already
    # O(log W) even without fusion, because each round is one layer).
    # ===================================================================

    # --- 3a: P-rounds.  For t = 1..T−1, for 1 ≤ m < ⌊W/2^t⌋ ---
    # P_t[m] ⊕= P_{t-1}[2m] AND P_{t-1}[2m+1]
    # where P_0[m] lives in b[m+1]  (paper's B[m] = p[m, m+1])
    # and    P_t[m] (t≥1) lives in  Ptm(t, m)
    for t in 1:(T - 1)
        for m in 1:(W >> t) - 1
            c1 = t == 1 ? b[2m + 1]     : Ptm(t - 1, 2m)     # P_{t-1}[2m]
            c2 = t == 1 ? b[2m + 2]     : Ptm(t - 1, 2m + 1) # P_{t-1}[2m+1]
            # Careful: paper indexes P_{t-1}[2m] with 2m in 0-based m domain.
            # In our 1-based m, P_0[2m] = b[2m + 1] because b[k+1] = P_0[k].
            # And P_{t-1}[2m] for t≥2 = Ptm(t-1, 2m) — still 1-based.
            push!(gates, ToffoliGate(c1, c2, Ptm(t, m)))
        end
    end

    # --- 3b: G-rounds.  For t = 1..T, for 0 ≤ m < ⌊W/2^t⌋ ---
    # G[2^t m + 2^t] ⊕= G[2^t m + 2^{t-1}] AND P_{t-1}[2m+1]
    # Julia: Z[2^t m + 2^t + 1]  ⊕=  Z[2^t m + 2^{t-1} + 1]  AND  P_{t-1}[2m+1]
    # For t = 1: P_0[2m+1] = b[2m+2]
    for t in 1:T
        for m in 0:(W >> t) - 1
            g_tgt   = Z[(m << t) + (1 << t)   + 1]  # G[2^t m + 2^t]
            g_ctrl  = Z[(m << t) + (1 << (t-1)) + 1]  # G[2^t m + 2^{t-1}]
            p_ctrl  = t == 1 ? b[2m + 2] : Ptm(t - 1, 2m + 1)
            push!(gates, ToffoliGate(g_ctrl, p_ctrl, g_tgt))
        end
    end
    # After 3b: Z[2^t + 1] = g[0, 2^t] = c_{2^t} for t = 1..T (the "power-of-2" carries).
    # All other Z[j+1] still hold block-g values g[?, j], not c_j.

    # --- 3c: C-rounds.  For t = ⌊log(2W/3)⌋ down to 1, for 1 ≤ m ≤ ⌊(W−2^{t−1})/2^t⌋ ---
    # G[2^t m + 2^{t-1}] ⊕= G[2^t m] AND P_{t-1}[2m]
    # Julia: Z[2^t m + 2^{t-1} + 1] ⊕= Z[2^t m + 1] AND P_{t-1}[2m]
    # For t = 1: P_0[2m] = b[2m + 1]
    T_C = floor(Int, log2(2W ÷ 3))   # = 1 + ⌊log₂(W/3)⌋ when W ≥ 3
    for t in T_C:-1:1
        m_max = (W - (1 << (t-1))) >> t
        for m in 1:m_max
            g_tgt  = Z[(m << t) + (1 << (t-1)) + 1]  # G[2^t m + 2^{t-1}]
            g_ctrl = Z[(m << t) + 1]                  # G[2^t m]  (already = c_{2^t m})
            p_ctrl = t == 1 ? b[2m + 1] : Ptm(t - 1, 2m)
            push!(gates, ToffoliGate(g_ctrl, p_ctrl, g_tgt))
        end
    end
    # After 3c: Z[j+1] = g[0, j] = c_j  for all 1 ≤ j ≤ W.

    # --- 3d: P^{-1}-rounds.  Reverse 3a in reverse order. ---
    # Same Toffolis, reverse sequence ⇒ Xflat returns to zero.
    for t in (T - 1):-1:1
        for m in ((W >> t) - 1):-1:1
            c1 = t == 1 ? b[2m + 1]     : Ptm(t - 1, 2m)
            c2 = t == 1 ? b[2m + 2]     : Ptm(t - 1, 2m + 1)
            push!(gates, ToffoliGate(c1, c2, Ptm(t, m)))
        end
    end

    # ===================================================================
    # PHASE 4: Form sum bits.  Z[i] ⊕= b[i]   for 0 ≤ i < W  (paper)
    # Julia: Z[k] ⊕= b[k]  for k = 1..W
    # After: Z[1] = b_0   ;  Z[k] = c_{k-1} ⊕ p_{k-1} = s_{k-1}  for k ≥ 2
    # ===================================================================
    for k in 1:W
        push!(gates, CNOTGate(b[k], Z[k]))
    end

    # ===================================================================
    # PHASE 5: Restore b, finalize s_0.
    #   5a) Z[1] ⊕= a[1]       (fixes Z[1] from b_0 to a_0 ⊕ b_0 = s_0)
    #   5b) b[k] ⊕= a[k] for k = 2..W   (undoes phase 2)
    # ===================================================================
    push!(gates, CNOTGate(a[1], Z[1]))
    for k in 2:W
        push!(gates, CNOTGate(a[k], b[k]))
    end

    return Z    # length W+1
end
```

Supporting helpers (file-local):

```julia
_popcount(x::Int) = count_ones(UInt(x))   # w(n)

"""0-based start of P_t within Xflat, for 1 ≤ t ≤ T-1. p_offsets[1] = 0."""
function _qcla_level_offsets(W::Int, T::Int)
    offs = Vector{Int}(undef, T)   # offs[1..T-1] meaningful; offs[T] unused
    acc = 0
    for t in 1:(T - 1)
        offs[t] = acc
        acc += (W >> t) - 1
    end
    return offs
end

"""Fallback adder for W ≤ 3: plain ripple-carry producing W+1 output bits."""
function _lower_add_small_outplace!(gates, wa, a, b, W)
    # Wrap the existing W-bit lower_add! and append a one-bit carry-out.
    # Simplest: allocate (W+1)-bit result, run ripple across all W+1 lanes
    # with b extended by a zero at position W+1. Keep it tiny — this path
    # is only hit for W ∈ {1,2,3}.
    Z = allocate!(wa, W + 1)
    carry = allocate!(wa, W + 1)
    # ripple  (same body as lower_add!, over W+1 bits, with a[W+1]=b[W+1]=0)
    for i in 1:W
        push!(gates, CNOTGate(a[i], Z[i]))
        push!(gates, CNOTGate(b[i], Z[i]))
        push!(gates, ToffoliGate(a[i], b[i], carry[i + 1]))
        push!(gates, ToffoliGate(Z[i], carry[i], carry[i + 1]))
        push!(gates, CNOTGate(carry[i], Z[i]))
    end
    push!(gates, CNOTGate(carry[W + 1], Z[W + 1]))  # carry-out
    return Z
end
```

---

## 4. Cost formulas in `W`

Using `w(·)` for Hamming weight and `lg` for `⌊log₂ ·⌋`, from the paper
Table 2 (§ "+ in ℤ, out-of-place, no incoming carry"):

| Metric             | Closed form                                               |
|--------------------|-----------------------------------------------------------|
| Toffoli count      | `5W − 3 w(W) − 3 lg(W) − 1`                               |
| Toffoli-depth      | `lg(W) + lg(W/3) + 4`                                     |
| CNOT count         | `3W − 1`                                                  |
| NOT count          | `0`                                                       |
| Total gate count   | `(5W − 3 w(W) − 3 lg(W) − 1) + (3W − 1) = 8W − 3 w(W) − 3 lg(W) − 2` |
| Total depth        | `lg(W) + lg(W/3) + 7`                                     |
| Ancilla count      | `W − w(W) − lg(W)` (excluding the W+1 output wires)       |
| Peak wires used    | `2W + (W + 1) + (W − w(W) − lg(W)) = 4W + 1 − w(W) − lg(W)` |

Per-phase breakdown (sanity):

| Phase                       | Toffoli          | CNOT | NOT |
|-----------------------------|------------------|------|-----|
| 1 (init g)                  | `W`              | 0    | 0   |
| 2 (init p)                  | 0                | `W−1`| 0   |
| 3a (P-rounds)               | `W − w(W) − lg(W)` | 0  | 0   |
| 3b (G-rounds)               | `Σ_{t=1..lg(W)} ⌊W/2^t⌋ = W − w(W)` | 0 | 0 |
| 3c (C-rounds)               | `Σ_{t=1..lg(2W/3)} ⌊(W − 2^{t−1})/2^t⌋` | 0 | 0 |
| 3d (P^{-1}-rounds)          | `W − w(W) − lg(W)` | 0  | 0   |
| 4 (form s)                  | 0                | `W`  | 0   |
| 5 (restore b + finalize s_0)| 0                | `W`  | 0   |
| **total**                   | `5W − 3 w(W) − 3 lg(W) − 1` | `3W−1` | 0 |

Numeric verification for `W = 4, 8, 16, 32, 64`:

| W  | 3a | 3b | 3c | 3d | 3-sum | 1+3 sum | formula |
|----|----|----|----|----|-------|---------|---------|
|  4 |  1 |  3 |  1 |  1 |   6   |   10    |   10 ✓  |
|  8 |  4 |  7 |  4 |  4 |  19   |   27    |   27 ✓  |
| 16 | 11 | 15 | 11 | 11 |  48   |   64    |   64 ✓  |
| 32 | 26 | 31 | 26 | 26 | 109   |  141    |  141 ✓  |
| 64 | 57 | 63 | 57 | 57 | 234   |  298    |  298 ✓  |

The paper derives phases 3a–3d from §3, equation (4): `4n − 3w(n) − 3⌊log n⌋ − 1`
Toffoli gates in the carry circuit. Adding the `W` Toffolis of phase 1 gives
our total of `5W − 3w(W) − 3⌊log W⌋ − 1`.

Comparison table:

| Primitive          | Toffoli       | Depth              | Ancilla (not counting output) |
|--------------------|---------------|--------------------|-------------------------------|
| `lower_add!`       | `2(W−1)`      | `≈ 2W`             | `W` (carry reg)               |
| `lower_add_cuccaro!`| `2W`         | `≈ 2W`             | `1`                           |
| `lower_add_qcla!`  | `~5W − 3 lg W`| `~2 lg W + 7`      | `~W − lg W`                   |

QCLA trades `~3× more Toffolis` for `O(log W)` depth vs. `O(W)` for ripple —
useful for W = 32 or W = 64 where depth dominates circuit runtime.

---

## 5. Worked W = 4 trace

For W = 4:
- `T = ⌊log₂ 4⌋ = 2`, so we have P-levels 1..T−1 = {1} only.
- `T_C = ⌊log(8/3)⌋ = ⌊log 2.67⌋ = 1`.
- `N_anc = 4 − w(4) − T = 4 − 1 − 2 = 1`. Single ancilla in `Xflat`.

Wire assignments (assume fresh allocator; call at wire counter = 1):
- `a = [1, 2, 3, 4]`    (caller-supplied; shown here as starting at 1 for clarity)
- `b = [5, 6, 7, 8]`    (caller-supplied)
- `Z = allocate!(wa, 5) = [9, 10, 11, 12, 13]`
- `Xflat = allocate!(wa, 1) = [14]`, so `P_1[1]` = wire 14.

Checking derived indices:
- `Ptm(1, 1) = Xflat[0 + 1] = 14` ✓ (there is no P_2 since T − 1 = 1)

The gates emitted, in order:

**Phase 1 (4 Toffolis — init g):**
```
Toffoli(a[1]=1,  b[1]=5,  Z[2]=10)     # g[0,1] → Z[2]
Toffoli(a[2]=2,  b[2]=6,  Z[3]=11)     # g[1,2] → Z[3]
Toffoli(a[3]=3,  b[3]=7,  Z[4]=12)     # g[2,3] → Z[4]
Toffoli(a[4]=4,  b[4]=8,  Z[5]=13)     # g[3,4] → Z[5]
```

**Phase 2 (3 CNOTs — init p):**
```
CNOT(a[2]=2, b[2]=6)    # b[2] := b_1 ⊕ a_1 = p[1,2]
CNOT(a[3]=3, b[3]=7)    # b[3] := p[2,3]
CNOT(a[4]=4, b[4]=8)    # b[4] := p[3,4]
```
State after phase 2: Z[2..5] = g-base, b[2..4] = p-base, b[1] = b_0 unchanged.

**Phase 3a (P-rounds), t = 1, m ∈ {1} (range `1 ≤ m < ⌊4/2⌋ = 2`):**
```
Toffoli(b[3]=7, b[4]=8, Xflat[1]=14)   # P_1[1] = p[2,3] AND p[3,4] = p[2,4]
```
(1 Toffoli.)

**Phase 3b (G-rounds), t = 1..T = 2:**

t = 1, m ∈ {0, 1}  (range `0 ≤ m < ⌊4/2⌋ = 2`):
```
m=0:  Toffoli(Z[2]=10, b[2]=6, Z[3]=11)  # G[2] ⊕= G[1] AND P_0[1]
                                         #   = g[0,1] AND p[1,2]
                                         # upgrades Z[3] from g[1,2] to g[0,2] = c_2
m=1:  Toffoli(Z[4]=12, b[4]=8, Z[5]=13)  # G[4] ⊕= G[3] AND P_0[3]
                                         # upgrades Z[5] from g[3,4] to g[2,4]
                                         # (note: NOT yet c_4 — only g[2,4] so far)
```

t = 2, m ∈ {0}  (range `0 ≤ m < ⌊4/4⌋ = 1`):
```
m=0:  Toffoli(Z[3]=11, Xflat[1]=14, Z[5]=13)
                                         # G[4] ⊕= G[2] AND P_1[1]
                                         # = g[0,2] AND p[2,4]
                                         # upgrades Z[5] from g[2,4] to g[0,4] = c_4
```
(3 Toffolis.)

After phase 3b:
  `Z[2] = g[0,1] = c_1`      (carry-power-of-2: t=0 trivially, written in phase 1)
  `Z[3] = g[0,2] = c_2`      (upgraded in G-round t=1, m=0)
  `Z[4] = g[2,3]`            (block-g, NOT yet c_3)
  `Z[5] = g[0,4] = c_4`      (upgraded in G-round t=2, m=0)

**Phase 3c (C-rounds), t = T_C..1 = 1..1:**

t = 1, m ∈ {1}  (range `1 ≤ m ≤ ⌊(4 − 1)/2⌋ = 1`):
```
m=1:  Toffoli(Z[3]=11, b[3]=7, Z[4]=12)  # G[3] ⊕= G[2] AND P_0[2]
                                         # = c_2 AND p[2,3]
                                         # upgrades Z[4] from g[2,3] to g[0,3] = c_3
```
(1 Toffoli.)

After phase 3c: `Z[2]=c_1, Z[3]=c_2, Z[4]=c_3, Z[5]=c_4`. All carries present.

**Phase 3d (P^{-1}-rounds), reverse of 3a:**
```
Toffoli(b[3]=7, b[4]=8, Xflat[1]=14)   # undoes phase 3a's write; Xflat[1] back to 0
```
(1 Toffoli.)

Cumulative Toffoli count through phase 3: 4 + 1 + 3 + 1 + 1 = **10 Toffolis**.

Paper formula: `5W − 3 w(W) − 3 lg(W) − 1 = 20 − 3 − 6 − 1 = 10`. ✓

**Phase 4 (4 CNOTs — form s):**
```
CNOT(b[1]=5,  Z[1]=9)    # Z[1] := 0 ⊕ b_0 = b_0
CNOT(b[2]=6,  Z[2]=10)   # Z[2] := c_1 ⊕ p_1 = s_1
CNOT(b[3]=7,  Z[3]=11)   # Z[3] := c_2 ⊕ p_2 = s_2
CNOT(b[4]=8,  Z[4]=12)   # Z[4] := c_3 ⊕ p_3 = s_3
```

**Phase 5 (4 CNOTs — restore b, finalize s_0):**
```
CNOT(a[1]=1,  Z[1]=9)    # Z[1] := b_0 ⊕ a_0 = s_0
CNOT(a[2]=2, b[2]=6)     # b[2] := p[1,2] ⊕ a_1 = b_1 (restored)
CNOT(a[3]=3, b[3]=7)     # b[3] := b_2 (restored)
CNOT(a[4]=4, b[4]=8)     # b[4] := b_3 (restored)
```

Total CNOTs: 3 + 4 + 4 = **11 CNOTs**. Paper formula: `3W − 1 = 11`. ✓

Grand total: **10 Toffoli + 11 CNOT = 21 gates**, no NOTs. ✓ Matches
`8W − 3 w(W) − 3 lg(W) − 2 = 32 − 3 − 6 − 2 = 21`. ✓

Final state:
- `Z[1] = s_0`, `Z[2] = s_1`, `Z[3] = s_2`, `Z[4] = s_3`, `Z[5] = s_4 = carry-out`
- `a[1..4]` unchanged
- `b[1..4]` restored to inputs
- `Xflat[1] = 0` (ancilla clean)

---

## 6. Edge cases

### W = 1
- `T = ⌊log₂ 1⌋ = 0`, so phases 3a, 3b, 3c, 3d are all empty loops.
- `N_anc = 1 − 1 − 0 = 0` → skip the `Xflat` allocation.
- Phase 1: `Toffoli(a[1], b[1], Z[2])` → `Z[2] = a_0 b_0 = carry-out = s_1`.
- Phase 2: empty (loop starts at k=2).
- Phase 4: `CNOT(b[1], Z[1])` → `Z[1] = b_0`.
- Phase 5: `CNOT(a[1], Z[1])` → `Z[1] = a_0 ⊕ b_0 = s_0`. Loop k=2..1 is empty.

Total: 1 Toffoli + 2 CNOT, depth 2. This is actually the optimal single-bit
full-adder (out-of-place, carry-out separated), so we could serve W=1 without
the fallback — but in the pseudocode I delegate to `_lower_add_small_outplace!`
for uniformity and to keep `lower_add_qcla!` focused on the log-depth regime.

### W = 2
- `T = 1`, so P-level 1..T−1 = 1..0 is empty; no P-rounds, no P^{-1}-rounds.
- G-round runs for t = 1 only: m ∈ {0}. One Toffoli: `Z[3] ⊕= Z[2] AND b[2]`
  upgrades Z[3] from g[1,2] to c_2 = g[0,2].
- C-round: `T_C = ⌊log(4/3)⌋ = 0`, so no C-rounds (the outer `for t in 0:-1:1`
  is empty).
- `N_anc = 2 − 1 − 1 = 0`, so no Xflat allocation.

Phase 1 (2 Tof) + Phase 2 (1 CNOT) + Phase 3b (1 Tof) + Phase 4 (2 CNOT) +
Phase 5 (2 CNOT) = **3 Toffoli, 5 CNOT, depth = 4**. Again, same cost as
ripple-carry, and falling through to `_lower_add_small_outplace!` gives
(roughly) the same numbers.

**Decision:** use the small-fallback path for `W ≤ 3`. The paper's formula
overcounts the depth for small W (paper §3 footnote), and the tree benefit
only kicks in at W ≥ 4.

### W = 4 — worked above.

### W = 8
- `T = 3`, T_C = `⌊log(16/3)⌋ = 2`.
- P-levels 1..2 → two levels of P-ancillae.
- `N_anc = 8 − 1 − 3 = 4`. Xflat layout:
  - P_1: slots 1..(⌊8/2⌋−1)=3 → `Xflat[1..3]` = `P_1[1], P_1[2], P_1[3]`
  - P_2: slots 1..(⌊8/4⌋−1)=1 → `Xflat[4]` = `P_2[1]`
- Predicted Toffoli count: `5·8 − 3·1 − 3·3 − 1 = 40 − 3 − 9 − 1 = 27`.
- Predicted CNOT: `3·8 − 1 = 23`.
- Predicted Toffoli-depth: `3 + ⌊log(8/3)⌋ + 4 = 3 + 1 + 4 = 8` — with the
  paper's timeslice fusion, the actual achievable depth is `3 + 1 + 4 = 8`.
  Without fusion (our initial naïve implementation), depth is closer to
  `T + T + T_C + T = 10`, which is still O(log W).

### W = 16
- `T = 4`, T_C = `⌊log(32/3)⌋ = 3`.
- `N_anc = 16 − 1 − 4 = 11`.
- Toffoli: `5·16 − 3·1 − 3·4 − 1 = 64`. Depth ≈ 11 (unfused) / 8 (fused).

### W = 64 (the motivating case — Int64)
- `T = 6`, T_C = `⌊log(128/3)⌋ = 5`.
- `N_anc = 64 − 1 − 6 = 57`.
- Toffoli: `5·64 − 3·1 − 3·6 − 1 = 298`.
- Total gates: `8·64 − 3 − 18 − 2 = 489`.
- Toffoli-depth (fused): `6 + 5 + 4 = 15`.

Compare to `lower_add!` at W=64: Toffoli = `2·63 = 126`, depth ≈ 128.
QCLA has 2.4× more Toffolis but **8.5× shallower depth**. For a function
whose critical path has a long chain of additions (soft-float
normalization, multi-precision reductions), QCLA dominates.

### Very large W (W > 64, not yet a Bennett.jl target but worth noting)
- Ancilla growth is asymptotically W, so the peak wire count of a
  circuit built on top of QCLA is ~ 4W per addition (inputs + output + tree).
- For compound operations (multiplication built from W adds), Bennett's
  outer construction combined with linear ancilla growth per add means
  peak wires scale as O(W × ops), which is the same ballpark as
  ripple-based compound operations. No new scaling surprises.

### Interaction with `lower.jl` Cuccaro-selection heuristic
`lower.jl` currently selects `lower_add_cuccaro!` when the op2 liveness
analysis says the second operand is dead after the add. We keep QCLA
**separate**: it is a **caller-requested** primitive, selected by
dispatching on a new keyword such as `add_strategy=:qcla`. The default
(`:auto`) stays `lower_add!` / `lower_add_cuccaro!` as today.
Rationale: QCLA is only beneficial when the user cares about depth, and
it costs ~3× more Toffolis — silently flipping to it would regress the
baseline gate counts tracked by `test_gate_count_regression.jl`.

---

## 7. Test plan

New test file `test/test_qcla.jl` under `test/` and registered in
`test/runtests.jl`. Tests, in increasing strictness:

### 7.1 Correctness

```julia
@testset "QCLA correctness — exhaustive small W" begin
    for W in 1:8
        c = _build_qcla_circuit(W)
        mask = UInt64((UInt64(1) << W) - 1)
        for a in 0:(1<<W)-1, b in 0:(1<<W)-1
            got = simulate(c, (a, b))         # returns (W+1)-bit sum
            want = (a + b) & ((UInt64(1) << (W+1)) - 1)
            @test UInt64(got) == want
        end
        @test verify_reversibility(c)
    end
end
```

`_build_qcla_circuit(W)` is a small test helper that allocates two W-bit
inputs, calls `lower_add_qcla!` directly on raw gates + allocator
without going through Julia IR, wraps the result in a `ReversibleCircuit`
(mimicking what `lower.jl` would do), and returns it.

### 7.2 Sampled correctness at Int widths

```julia
@testset "QCLA — Int16 / Int32 / Int64 sampled" begin
    for W in (16, 32, 64)
        c = _build_qcla_circuit(W)
        rng = MersenneTwister(0xBEEF + W)
        for _ in 1:2000
            a = rand(rng, UInt64) & ((UInt64(1)<<W) - 1)
            b = rand(rng, UInt64) & ((UInt64(1)<<W) - 1)
            got = simulate(c, (a, b))
            want = (a + b) & ((UInt64(1) << (W+1)) - 1)
            @test UInt64(got) == want
        end
        @test verify_reversibility(c)
    end
end
```

Edge-case inputs also included explicitly: `(0, 0)`, `(2^W - 1, 2^W - 1)`
(max + max → carry-out set), `(2^{W-1}, 2^{W-1})` (sign-bit carry),
`(0x5555..., 0xAAAA...)` (alternating), etc.

### 7.3 Gate-count pins (regression baselines per CLAUDE.md §6)

```julia
@testset "QCLA — gate count pins" begin
    # These pins come from the paper Table 2 formulas.
    # Changes here are red flags per CLAUDE.md §6.
    expected = Dict{Int, NamedTuple}(
         4 => (tof=10,  cnot=11,  not=0, anc=1),    # worked example
         8 => (tof=27,  cnot=23,  not=0, anc=4),
        16 => (tof=64,  cnot=47,  not=0, anc=11),
        32 => (tof=141, cnot=95,  not=0, anc=26),
        64 => (tof=298, cnot=191, not=0, anc=57),
    )
    for (W, exp) in expected
        c = _build_qcla_circuit(W)
        gc = gate_count(c)
        @test gc.Toffoli == exp.tof
        @test gc.CNOT    == exp.cnot
        @test gc.NOT     == exp.not
        @test ancilla_count(c) == exp.anc + (W+1)  # output is also ancilla
                                                    # if we test via bennett wrapping;
                                                    # for raw-lowered test it's just exp.anc
    end
end
```

Derivation of the numbers above (all from Table 2):
  - W=4:  tof = 5·4 − 3·1 − 3·2 − 1 = 10,   cnot = 3·4 − 1 = 11, anc = 4 − 1 − 2 = 1
  - W=8:  tof = 40 − 3 − 9 − 1    = 27,    cnot = 23, anc = 4
  - W=16: tof = 80 − 3 − 12 − 1   = 64,    cnot = 47, anc = 11
  - W=32: tof = 160 − 3 − 15 − 1  = 141,   cnot = 95, anc = 26
  - W=64: tof = 320 − 3 − 18 − 1  = 298,   cnot = 191, anc = 57

### 7.4 Toffoli-depth sanity

```julia
@testset "QCLA — log-depth guarantee" begin
    for W in (8, 16, 32, 64)
        c = _build_qcla_circuit(W)
        td = toffoli_depth(c)
        # Paper's unfused upper bound from §3 + phase 1 Toffolis:
        #   phase 1 contributes 1 layer (all independent),
        #   tree contributes ≤ 4 * lg(W) − O(1) before fusion.
        # We assert td ≤ 3 * lg(W) + 10 — generous, so passing doesn't
        # pin a fragile precise number, but still catches any O(W)
        # regression.
        @test td <= 3 * floor(Int, log2(W)) + 10
        @test td >= floor(Int, log2(W))       # sanity lower bound
    end
end
```

Once a time-slice-fusion pass lands, tighten the upper bound to
`lg(W) + lg(W/3) + 4` and include it as a hard pin.

### 7.5 Cross-check against `lower_add!` and `lower_add_cuccaro!`

```julia
@testset "QCLA agrees with ripple on all Int8 pairs" begin
    qcla = _build_qcla_circuit(8)
    for a in 0:255, b in 0:255
        sQ = simulate(qcla, (a, b))                 # 9-bit sum
        sR = (a + b) & 0x1FF                         # integer reference
        @test UInt64(sQ) == sR
    end
end
```

### 7.6 Integration test (via `reversible_compile` once `lower.jl`
     dispatches to QCLA)

Pending a follow-up issue to wire QCLA into `lower.jl` behind a
keyword / attribute. Planned test shape:

```julia
@testset "QCLA via reversible_compile" begin
    f(x::Int32, y::Int32) = x + y
    c = reversible_compile(f, Int32, Int32; add_strategy=:qcla)
    for _ in 1:200
        a = rand(Int32); b = rand(Int32)
        @test simulate(c, (a, b)) == (a + b)
    end
    @test verify_reversibility(c)
    # pin a known gate-count once stable
end
```

### 7.7 Ancilla hygiene (built into `verify_reversibility`)

`simulate` already errors if any ancilla wire is non-zero at the end
(see `simulator.jl:32`). Every correctness test above is therefore
also an ancilla-hygiene test — no additional harness needed.

### 7.8 Stress test

```julia
@testset "QCLA W=64 large-sample" begin
    c = _build_qcla_circuit(64)
    rng = MersenneTwister(0xC0FFEE)
    for _ in 1:10_000
        a = rand(rng, UInt64); b = rand(rng, UInt64)
        @test UInt64(simulate(c, (a, b))) == (UInt128(a) + UInt128(b)) & ((UInt128(1) << 65) - 1)
    end
end
```

---

## Summary / key design decisions

1. **Out-of-place, self-uncomputing** — matches paper §4.1 verbatim so
   we can pin every phase's gate count against Table 2 and simulate
   the primitive standalone. Requires W+1-bit output register.
2. **Flat ancilla block `Xflat` with computed offsets** — one
   `allocate!` call for the entire P-tree, indexed by a simple
   `_qcla_level_offsets` helper. Keeps the wire allocator untouched.
3. **`W ≤ 3` delegates to a tiny ripple helper** — avoids fragile
   edge-case code in the log-depth hot path; matches the paper's
   observation that formulas overcount at small W.
4. **Algorithm emitted in paper-canonical order** — P → G → C → P^{-1}
   → sum — without timeslice fusion. Fusion is a pure optimisation
   that does not affect correctness and can be added later as a
   depth-reducing pass, gated by a pin in `test_qcla_depth.jl`.
5. **`lower_add_qcla!` is *not* auto-dispatched from `lower.jl`** —
   Opt-in via a caller-chosen strategy keyword. Protects the existing
   ripple / Cuccaro regression baselines while letting
   depth-sensitive callers pick QCLA explicitly.
