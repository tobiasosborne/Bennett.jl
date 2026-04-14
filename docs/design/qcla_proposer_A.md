# Proposer A — Quantum Carry-Lookahead Adder (QCLA)

Reference: Draper, Kutin, Rains, Svore (2004), "A Logarithmic-Depth Quantum
Carry-Lookahead Adder", arXiv:quant-ph/0406142. PDF at
`docs/literature/arithmetic/draper-kutin-rains-svore-2004.pdf`.

## Section 1 — Algorithm shape

We implement the **out-of-place** variant from Section 4.1 of the paper, which
is the cleanest fit for Bennett's construction wrapper:

- Inputs `a, b` are untouched after the adder runs.
- Result is written into a freshly allocated register `Z` of width `W+1`
  (low `W` bits of sum, plus the overflow bit `c_W`).
- All scratch space (propagate tree, generate tree, internal `P_t` arrays)
  returns to zero at the end.

**Why out-of-place over in-place.**

Bennett's construction (`src/bennett.jl`) computes `forward + CNOT-copy + reverse`.
An out-of-place adder leaves `a` and `b` pristine, so the outer Bennett wrap is
trivial: the forward pass writes `Z`, the copy pass copies `Z` to the output
register, and the reverse pass uncomputes `Z`. An in-place adder (which would
overwrite `b` with `a+b`) requires the caller to think about which register
is "the answer" and the lower-level uncompute story is more delicate — the paper
literally has to run the adder forward, complement the result, run it backward,
and complement again (Section 4.2, 14 extra steps). That's ten more Toffolis
and roughly 2× the depth. Since `lower_add!` (ripple) is also out-of-place,
keeping the same contract preserves drop-in replacement in `lower.jl`.

**In-place variant is deferred** to a follow-up PRD item — the out-of-place
version is sufficient to demonstrate logarithmic depth and is the variant
called by the classical CLA textbook treatments.

**Algorithm at a glance** (reproduced from Section 4.1 with 1-based translation):

1. Initialise `Z[i+1] = a_i · b_i = g[i,i+1]` for every bit position
   (Toffoli per bit). These are the **base generate bits**; they live on the
   Z wires themselves — the "generate array" is the output register.
2. Store **base propagate bits** `p[i,i+1] = a_i ⊕ b_i` on top of `b` via
   `B[i] ⊕= A[i]` for i ≥ 1. Position i=0 is left alone (carry-in is 0 so
   `p[0,1]` is never needed in its propagate role — see Remark P0 below).
3. Run the **carry-status circuit** (Section 3) using an ancilla register
   `X` of width `W - w(W) - floor(log W)`. At the end, `Z[i] = c_i` for
   i ≥ 1 and `X` is back to zero.
4. XOR `b`'s propagate bits into `Z` to turn carries into sum bits:
   `Z[i] ⊕= B[i]` for every i. Now `Z[i] = a_i ⊕ b_i ⊕ c_i = s_i` for i ≥ 1.
5. Restore `B` to its original value and patch `Z[0] = s_0 = a_0 ⊕ b_0`:
   `Z[0] ⊕= A[0]`, then `B[i] ⊕= A[i]` for i ≥ 1 (undo step 2).

The carry-status circuit itself has four subphases: P-rounds, G-rounds,
C-rounds, and P⁻¹-rounds. The P-rounds build a tree of `P_t[m] = p[i, i+2^t]`
propagate values into the X ancillae. The G-rounds climb the generate tree,
combining `G[j] ⊕= G[i] · P_{t-1}[...]` and overwriting the `G` wires
(which are the Z wires) in place. The C-rounds fill in the remaining carry
positions that were skipped by the G-rounds. The P⁻¹-rounds uncompute the
X ancillae by replaying the P-round Toffolis in reverse — since each Toffoli
is self-inverse this cleans X exactly.

Remark P0. Because carry-in is fixed to 0, `p[0,1]` never participates in
the lookahead tree: we only ever compute `p[i,j]` for i ≥ 1, which is why
step 2 leaves `B[0]` alone. This is why Section 3 says "For all j > 0,
p[0,j] is 0, and g[0,j] is the carry bit c_j".

## Section 2 — Wire layout

Bennett.jl is 1-indexed throughout (bit 1 = LSB). The paper uses 0-based
indexing for bits and rounds. The translation table is:

| Paper (0-based)     | Bennett.jl (1-based)          |
|---------------------|-------------------------------|
| `a[i]` for 0≤i<n    | `a[i+1]` for 1≤i+1≤W          |
| `b[i]` for 0≤i<n    | `b[i+1]` for 1≤i+1≤W          |
| `Z[i]` for 0≤i≤n    | `Z[i+1]` for 1≤i+1≤W+1        |
| `P_t[m]` for 1≤m    | `P[t][m]` keyed by `(t,m)` → wire index via table |
| `G[j]` for 0≤j≤n    | same as `Z[j+1]`, aliased      |

We keep paper-index semantics internally (as `Dict{Tuple{Int,Int},Int}` for `P`)
so the code reads directly against Section 3's equations. Only the caller-facing
arrays are in Bennett.jl convention.

### 2.1 Input wires

- `a[1:W]` — W wires, a's bits, LSB first. **Unchanged** by the circuit.
- `b[1:W]` — W wires, b's bits, LSB first. **Unchanged** by the circuit.

### 2.2 Output wires

- `Z[1:W+1]` — W+1 freshly allocated wires, all zero on entry.
  - On exit: `Z[1] = s_0`, `Z[2] = s_1`, …, `Z[W] = s_{W-1}`, `Z[W+1] = c_W`
    (overflow bit, = `s_W` for a W+1-bit sum).

### 2.3 Ancilla wires

- `X` — `n_anc = W - w(W) - floor(log₂ W)` freshly allocated wires, all zero
  on entry, all zero on exit. These store internal propagate values
  `P_t[m] = p[2^t · m, 2^t · (m+1)]` for t ≥ 1.

  We compute a layout map at function entry:

  ```
  t from 1 to floor(log W) - 1
    for m from 1 to floor(W / 2^t) - 1          # note: strict <
      P[(t, m)] = X[next_x_index]
      next_x_index += 1
  ```

  Total slots consumed: `sum_{t=1}^{floor(log W)-1} (floor(W / 2^t) - 1)`
  which equals `W - w(W) - floor(log W)` by equation (1) of the paper.
  This identity is load-bearing — if the wire table runs out, we `error()`.

- `P_0[i]` is aliased to `b[i+1]` for i ≥ 1 (paper's step 2 of Sec 4.1).
  No separate allocation. In code we never name P_0 — we just read `b[i]`
  after step 2 is executed and note in a comment that it holds `p[i-1, i]`.

### 2.4 Summary table

| Role                     | Count        | Allocated by      | Zero on exit? |
|--------------------------|--------------|-------------------|---------------|
| `a` input                | W            | caller            | unchanged     |
| `b` input                | W            | caller            | unchanged     |
| `Z` output               | W+1          | `allocate!(wa,W+1)`| holds `a+b`   |
| `X` (P-tree scratch)     | W−w(W)−⌊log W⌋ | `allocate!(wa,n_anc)` | zero       |

## Section 3 — Julia-like pseudocode

```julia
"""
Out-of-place logarithmic-depth QCLA (Draper–Kutin–Rains–Svore 2004).

Computes `result = a + b` with `W+1` result bits (low W bits of sum + carry-out).
`a` and `b` are unchanged. All scratch ancillae return to zero.

Toffoli count: 5W - 3w(W) - 3⌊log₂ W⌋ - 1   (for W ≥ 4)
CNOT count:    3W - 1
Toffoli depth: ⌊log₂ W⌋ + ⌊log₂ (W/3)⌋ + 7  (for W ≥ 4; lower for small W)
Ancillae:      W - w(W) - ⌊log₂ W⌋

For W ≤ 3 the log-depth machinery amortises poorly, so we fall back to
`lower_add!` (ripple-carry). See Section 6 for boundary-case justification.
"""
function lower_add_qcla!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                         a::Vector{Int}, b::Vector{Int}, W::Int)
    # ---- Boundary cases ----------------------------------------------------
    W >= 1 || error("lower_add_qcla!: W must be ≥ 1, got $W")
    length(a) == W || error("lower_add_qcla!: |a| = $(length(a)) ≠ W = $W")
    length(b) == W || error("lower_add_qcla!: |b| = $(length(b)) ≠ W = $W")
    # Small-W fallback. The CLA tree needs ⌊log W⌋ ≥ 1 to have any P-rounds
    # that amortise, and the formulas in the paper assume W ≥ 4. Below that,
    # ripple-carry is shorter and cheaper.
    if W < 4
        return lower_add!(gates, wa, a, b, W)
    end

    logW = floor(Int, log2(W))                        # paper's ⌊log n⌋
    popW = count_ones(W)                              # paper's w(n)
    n_anc = W - popW - logW                           # X-register size

    # ---- Wire allocation --------------------------------------------------
    Z = allocate!(wa, W + 1)                          # output / G-array + c_W
    X = n_anc > 0 ? allocate!(wa, n_anc) : Int[]      # internal P_t storage

    # Paper uses 0-based; we build a (t,m)->wire map matching Section 3.
    # P_0[i] is aliased to b[i+1] (1-based) for 1 ≤ i ≤ W-1.
    P = Dict{Tuple{Int,Int},Int}()
    nx = 1
    for t in 1:(logW - 1)
        # P-round t writes P_t[m] for 1 ≤ m < ⌊W/2^t⌋
        for m in 1:(div(W, 1 << t) - 1)
            nx <= n_anc || error("QCLA: X ancilla overflow at t=$t m=$m")
            P[(t, m)] = X[nx]
            nx += 1
        end
    end
    nx - 1 == n_anc || error("QCLA: X ancilla undercount: used $(nx-1), expected $n_anc")

    # Helper: paper's P_0[i] = a_i XOR b_i, physically lives on b[i+1].
    # After step 2 (below), b[i+1] == p[i,i+1] for i ≥ 1.
    P0(i) = begin
        i == 0 && error("QCLA: P_0[0] is never read; algorithm bug")
        b[i + 1]     # 1-based wire index into caller's b-array
    end
    # Helper: paper's G[j] lives on Z[j+1] for 0 ≤ j ≤ W.
    G(j) = Z[j + 1]
    # Helper: paper's P_t[m] for t ≥ 1 lives on the (t,m) entry of P.
    Pt(t, m) = t == 0 ? P0(m) : P[(t, m)]

    # ---- Step 1 of Sec 4.1: Z[i+1] ⊕= a_i · b_i (0-based i = 0..n-1) ------
    # 1-based: for i in 1:W push Toffoli(a[i], b[i], Z[i+1])
    for i in 1:W
        push!(gates, ToffoliGate(a[i], b[i], Z[i + 1]))
    end

    # ---- Step 2: B[i] ⊕= A[i] for 1 ≤ i < n (0-based) --------------------
    # 1-based: for i in 2:W push CNOT(a[i], b[i])
    for i in 2:W
        push!(gates, CNOTGate(a[i], b[i]))
    end

    # ---- Step 3: the carry-status circuit (Section 3) --------------------
    _qcla_carry_status!(gates, W, logW, G, P0, Pt)

    # ---- Step 4: Z[i] ⊕= B[i] for 1 ≤ i < n  (turns carries into sums) ---
    # 1-based: for i in 2:W push CNOT(b[i], Z[i])
    for i in 2:W
        push!(gates, CNOTGate(b[i], Z[i]))
    end

    # ---- Step 5a: Z[0] ⊕= A[0]  -> 1-based Z[1] ⊕= a[1] ------------------
    push!(gates, CNOTGate(a[1], Z[1]))

    # ---- Step 5b: B[i] ⊕= A[i] for 1 ≤ i < n  (undo step 2) -------------
    for i in 2:W
        push!(gates, CNOTGate(a[i], b[i]))
    end

    # X ancillae are back to zero (P⁻¹ rounds ran inside _qcla_carry_status!).
    # We may free X so the next compile step can reuse the wires:
    isempty(X) || free!(wa, X)

    return Z     # length W+1, low W bits = sum mod 2^W, top bit = carry-out
end

# ---------------------------------------------------------------------------
# Internal: the 4-phase carry-status circuit (P, G, C, P⁻¹).
#
# Runs entirely by emission order — no "time slice" overlap.  The paper
# Section 3 suggests overlapping rounds for lower wall-clock depth, but
# Bennett.jl does not have a scheduler, and the Toffoli *count* is unchanged
# by overlap.  We emit strictly sequentially; a downstream depth-optimiser
# (future work) can re-order commuting gates.
# ---------------------------------------------------------------------------
function _qcla_carry_status!(gates, W::Int, logW::Int, G, P0, Pt)

    # ---- P-rounds: build P_t[m] = P_{t-1}[2m] ∧ P_{t-1}[2m+1] -----------
    # for t = 1 .. logW - 1, for 1 ≤ m < ⌊W / 2^t⌋
    for t in 1:(logW - 1)
        for m in 1:(div(W, 1 << t) - 1)
            # Paper: P_t[m] ⊕= P_{t-1}[2m] · P_{t-1}[2m+1]
            # In paper 0-based indexing, P_{t-1}[2m] and P_{t-1}[2m+1]
            # are the two children; since P_t[m] starts at zero, ⊕= is the
            # same as = for the first write.
            c1 = Pt(t - 1, 2m)
            c2 = Pt(t - 1, 2m + 1)
            tgt = Pt(t, m)
            push!(gates, ToffoliGate(c1, c2, tgt))
        end
    end

    # ---- G-rounds: propagate generate up the tree ------------------------
    # for t = 1 .. logW, for 0 ≤ m < ⌊W / 2^t⌋
    # G[2^t m + 2^t]  ⊕=  G[2^t m + 2^{t-1}] · P_{t-1}[2m+1]
    for t in 1:logW
        for m in 0:(div(W, 1 << t) - 1)
            j   = (1 << t) * m + (1 << t)             # target G[j]
            iG  = (1 << t) * m + (1 << (t - 1))       # G[iG] is a control
            mPt = 2m + 1                              # P_{t-1}[mPt] is other ctrl
            push!(gates, ToffoliGate(G(iG), Pt(t - 1, mPt), G(j)))
        end
    end

    # ---- C-rounds: fill the remaining carries ----------------------------
    # for t = ⌊log(2W/3)⌋ down to 1, for 1 ≤ m ≤ ⌊(W - 2^{t-1}) / 2^t⌋
    # G[2^t m + 2^{t-1}]  ⊕=  G[2^t m] · P_{t-1}[2m]
    # Note: this is the only phase where P_{t-1}[2m] (even index) is read
    # after G-rounds; for t=1 this reads P_0[2m] = b[2m+1] (post-step-2).
    t_hi = floor(Int, log2(2W / 3))
    for t in t_hi:-1:1
        for m in 1:div(W - (1 << (t - 1)), 1 << t)
            j   = (1 << t) * m + (1 << (t - 1))
            iG  = (1 << t) * m
            mPt = 2m
            push!(gates, ToffoliGate(G(iG), Pt(t - 1, mPt), G(j)))
        end
    end

    # ---- P⁻¹-rounds: uncompute the X ancillae ---------------------------
    # Reverse of the P-rounds.  Each Toffoli is self-inverse, so emitting
    # the *same* Toffolis in reverse t-order (and reverse m-order within
    # each t) zeroes X[] exactly.
    for t in (logW - 1):-1:1
        for m in (div(W, 1 << t) - 1):-1:1
            c1 = Pt(t - 1, 2m)
            c2 = Pt(t - 1, 2m + 1)
            tgt = Pt(t, m)
            push!(gates, ToffoliGate(c1, c2, tgt))
        end
    end
    return nothing
end
```

### 3.1 Gate-emission ordering contract (invariants)

The order above is deliberate. In particular:

1. **Step 1 before step 2**: Z[i+1] must read *original* a[i] AND b[i]. If we
   ran step 2 first, b[i] would already hold `a_i XOR b_i`, and
   `a_i · (a_i ⊕ b_i) = a_i · ¬b_i` — wrong.
2. **P-rounds before G-rounds**: G-round t=2 reads `P_1[m]`, which is
   written during the P-round at t=1.
3. **G-rounds before C-rounds**: C-rounds fill carries that the G-rounds
   skipped. The two phases do not commute in general because both write
   into G[].
4. **C-rounds before step 4**: step 4 reads `Z[i] = c_i`; this only holds
   after C-rounds complete.
5. **Step 4 before step 5**: step 5 uncomputes step 2 and fixes `Z[1]`; once
   step 5 runs, `b` no longer holds propagate bits, so step 4 must finish first.
6. **P⁻¹-rounds**: emitted last, after C-rounds. No step reads `P_t[m]`
   (for t ≥ 1) after the C-rounds, so the X register can be uncomputed
   independently. We emit P⁻¹ *before* step 4 in the paper's overlap
   schedule, but since we're not scheduling we place it last inside
   `_qcla_carry_status!` — the Toffoli count is unchanged and the invariant
   "X is zero on exit" is unaffected.

### 3.2 Uncompute strategy — fully explicit

The X ancillae are uncomputed by the P⁻¹-rounds, which are literally the
P-round Toffolis in reverse order. No Bennett-style "copy and reverse"
around the *adder as a whole* is needed at this layer — that is the job of
the outer `bennett()` wrapper. QCLA's internal uncompute is only for the
X register; `Z` is the *answer*, and `a`, `b` are pristine.

The property "each Toffoli is self-inverse and the target wire sees a
matched pair of flips whose controls are identical" is what makes the naive
reverse-the-gates uncompute correct here. Specifically:

- At the end of P-rounds, `X[k]` holds some `P_t[m] = AND of a pair of
  earlier values`.
- The intermediate `P_{t'}[m']` values on X were each written by exactly one
  Toffoli that has **never** had its controls touched again (G-rounds and
  C-rounds read P_t values but never write them).
- Therefore replaying those Toffolis in reverse order zeroes X exactly.

This is the CLAUDE.md principle #4 invariant: all ancillae return to zero.
The invariant is enforced in tests via `verify_reversibility`.

## Section 4 — Cost model

Let W be the input bit width. Define:

- `logW = ⌊log₂ W⌋`
- `w(W) = popcount(W)` (number of 1-bits in W's binary expansion)

The paper's formulas (Table 2, applied for n≥4; we fall back to ripple for
W<4).

### Toffoli count

| Phase                    | Toffolis                             |
|--------------------------|--------------------------------------|
| Step 1 (base generate)   | `W`                                  |
| P-rounds                 | `W - w(W) - logW`                    |
| G-rounds                 | `W - w(W)`                           |
| C-rounds                 | `W - logW - 1`                       |
| P⁻¹-rounds               | `W - w(W) - logW`                    |
| **Sum (carry-status)**   | `4W - 3w(W) - 3·logW - 1`            |
| **Grand total**          | `5W - 3w(W) - 3·logW - 1`            |

Checks at key widths:

| W  | w(W) | logW | Toffoli                        |
|----|------|------|--------------------------------|
| 4  | 1    | 2    | 20 − 3 − 6 − 1 = **10**        |
| 8  | 1    | 3    | 40 − 3 − 9 − 1 = **27**        |
| 16 | 1    | 4    | 80 − 3 − 12 − 1 = **64**       |
| 32 | 1    | 5    | 160 − 3 − 15 − 1 = **141**     |
| 64 | 1    | 6    | 320 − 3 − 18 − 1 = **298**     |

Contrast with ripple-carry `lower_add!` Toffoli = `2(W-1)`, so W=64 is
298 vs 126 — QCLA actually uses *more* Toffolis. QCLA's win is **depth**,
not count. This must be documented loud: `lower_add!` stays the default for
gate-count-sensitive callers; QCLA is opt-in when depth matters (which, for
the Sturm/quantum-control long-term goal, it does).

### CNOT count

| Phase     | CNOTs |
|-----------|-------|
| Step 2    | `W-1` |
| Step 4    | `W-1` |
| Step 5    | `W`   |
| **Total** | `3W-1` |

### NOT count

Zero. QCLA has no NOT gates (carry-in is implicitly 0, no need to flip).

### Toffoli depth

(Under the paper's overlap schedule — Bennett.jl's emission-order "depth"
is higher but can be recovered by a downstream scheduler.)

```
depth = logW + ⌊log(W/3)⌋ + 7           (for W ≥ 4)
      = ⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7
```

Concrete values (idealised):

| W   | depth |
|-----|-------|
| 4   | 2 + 0 + 7 = **9**    |
| 8   | 3 + 1 + 7 = **11**   |
| 16  | 4 + 2 + 7 = **13**   |
| 32  | 5 + 3 + 7 = **15**   |
| 64  | 6 + 4 + 7 = **17**   |
| 128 | 7 + 5 + 7 = **19**   |

Ripple-carry has depth `2W + O(1)`. QCLA crosses over at roughly W=8.

### Ancilla count

```
n_anc = W - w(W) - logW
```

Checks:

| W  | w(W) | logW | n_anc |
|----|------|------|-------|
| 4  | 1    | 2    | **1** |
| 8  | 1    | 3    | **4** |
| 16 | 1    | 4    | **11**|
| 32 | 1    | 5    | **26**|
| 64 | 1    | 6    | **57**|

Plus the `W+1` wires for Z. So total new wires per invocation:
`2W + 1 - w(W) - logW` = roughly `2W` — comparable to ripple's `2W`.

## Section 5 — Worked example, W = 4

We trace gate emission explicitly. Paper-index → wire-index:

| Paper name            | Role                     | Bennett wire |
|-----------------------|--------------------------|-------------|
| `a_0, a_1, a_2, a_3`  | operand a                | `a[1..4]`   |
| `b_0, b_1, b_2, b_3`  | operand b                | `b[1..4]`   |
| `Z[0..4]`             | output + generates       | `Z[1..5]`   |
| `P_1[1] = p[2,4]`     | only internal P wire     | `X[1]`      |

**Constants**: `W=4`, `logW=2`, `w(W)=1`, `n_anc = 4-1-2 = 1`.

### Gate sequence (20 gates total — 10 Toffoli + 10 CNOT, matching formulas)

```
(Step 1) — base generates into Z[i+1]
  1.  Toffoli(a[1], b[1], Z[2])    # Z[2] = a_0·b_0 = g[0,1]
  2.  Toffoli(a[2], b[2], Z[3])    # Z[3] = g[1,2]
  3.  Toffoli(a[3], b[3], Z[4])    # Z[4] = g[2,3]
  4.  Toffoli(a[4], b[4], Z[5])    # Z[5] = g[3,4]

(Step 2) — b[i] ← a_{i-1} ⊕ b_{i-1} for paper-i ≥ 1, i.e. 1-based 2..4
  5.  CNOT(a[2], b[2])             # b[2] = p[1,2]
  6.  CNOT(a[3], b[3])             # b[3] = p[2,3]
  7.  CNOT(a[4], b[4])             # b[4] = p[3,4]

(Step 3: carry-status)

(P-round, t=1, m=1 only — single Toffoli)
  8.  Toffoli(b[3], b[4], X[1])    # X[1] = P_1[1] = p[1,2]·p[2,3]? NO — wait.
```

Stop — let me check the indexing carefully. Paper says P-round t, m: writes
`P_t[m]` with children `P_{t-1}[2m], P_{t-1}[2m+1]`.

For t=1, m=1: children are `P_0[2] and P_0[3]`. In paper 0-based, `P_0[i] = p[i, i+1]`.
So `P_0[2] = p[2,3]` and `P_0[3] = p[3,4]`. Physically these are on `b[3]` and `b[4]`
(1-based) *after step 2*. So:

```
  8.  Toffoli(b[3], b[4], X[1])    # X[1] = p[2,3]·p[3,4] = p[2,4]. Good.
```

Continuing:

```
(G-round, t=1, m=0,1)
  9.  Toffoli(Z[2], b[2], Z[3])    # Z[3] ⊕= G(1)·P_0[1] = g[0,1]·p[1,2]
                                   # Now Z[3] = g[1,2] ⊕ g[0,1]·p[1,2] = g[0,2]
  10. Toffoli(Z[4], b[4], Z[5])    # Z[5] ⊕= G(3)·P_0[3] = g[2,3]·p[3,4]
                                   # Now Z[5] = g[3,4] ⊕ g[2,3]·p[3,4] = g[2,4]

(G-round, t=2, m=0)
  11. Toffoli(Z[3], X[1], Z[5])    # Z[5] ⊕= G(2)·P_1[1] = g[0,2]·p[2,4]
                                   # Now Z[5] = g[2,4] ⊕ g[0,2]·p[2,4] = g[0,4] = c_4

(C-round, t=1, m=1 — only one because ⌊(4-1)/2⌋=1)
  12. Toffoli(Z[3], b[3], Z[4])    # Z[4] ⊕= G(2)·P_0[2] = g[0,2]·p[2,3]
                                   # Now Z[4] = g[2,3] ⊕ g[0,2]·p[2,3] = g[0,3] = c_3

(P⁻¹-round, t=1, m=1)
  13. Toffoli(b[3], b[4], X[1])    # X[1] ⊕= p[2,3]·p[3,4]; X[1] back to 0

At end of step 3:
  Z[1]=0, Z[2]=c_1=g[0,1], Z[3]=c_2=g[0,2], Z[4]=c_3=g[0,3], Z[5]=c_4=g[0,4]
  X[1]=0
  b[2..4] hold p[1,2], p[2,3], p[3,4]
  b[1] unchanged

(Step 4) — turn carries into sums
  14. CNOT(b[2], Z[2])             # Z[2] = c_1 ⊕ p[1,2] = s_1
  15. CNOT(b[3], Z[3])             # Z[3] = c_2 ⊕ p[2,3] = s_2
  16. CNOT(b[4], Z[4])             # Z[4] = c_3 ⊕ p[3,4] = s_3

(Step 5a) — fix Z[1] = s_0
  17. CNOT(a[1], Z[1])             # Z[1] = a_0 — but s_0 = a_0 ⊕ b_0.

Hmm — that's wrong. Let me re-examine step 5 from the paper.
```

Reading the paper step 5 again: "Set `Z[0] ⊕= A[0]`. For `1 ≤ i < n`,
`B[i] ⊕= A[i]`. This fixes Z[0], and resets B to its initial value."

The reason step 5a only XORs `A[0]` into `Z[0]` (not `B[0]`) is that
`Z[0]` was set to something that already contains `B[0]` — check step 4:
"For `0 ≤ i < n`, `Z[i] ⊕= B[i]`." So step 4 writes all indices, including
i=0: `Z[0] ⊕= B[0] = b_0`. Then step 5 adds `a_0` → `Z[0] = a_0 ⊕ b_0 = s_0`. ✓

I had step 4 wrong above — it ranges over `0 ≤ i < n`, i.e. **every bit**.
Let me redo steps 4 and 5 of the gate sequence.

Corrected **step 4**: CNOT b[i] → Z[i] for **all 1 ≤ i ≤ W** (not 2..W).

```
(Step 4) — turn carries into sums (corrected: i = 0..n-1 ⇒ 1..W)
  14. CNOT(b[1], Z[1])             # Z[1] = 0 ⊕ b_0 = b_0
  15. CNOT(b[2], Z[2])             # Z[2] = c_1 ⊕ p[1,2] = s_1
  16. CNOT(b[3], Z[3])             # Z[3] = c_2 ⊕ p[2,3] = s_2
  17. CNOT(b[4], Z[4])             # Z[4] = c_3 ⊕ p[3,4] = s_3

(Step 5a) — fix Z[1] = s_0
  18. CNOT(a[1], Z[1])             # Z[1] = b_0 ⊕ a_0 = s_0

(Step 5b) — undo step 2 (restore b to original)
  19. CNOT(a[2], b[2])             # b[2] = p[1,2] ⊕ a_1 = b_1
  20. CNOT(a[3], b[3])             # b[3] = b_2
  21. CNOT(a[4], b[4])             # b[4] = b_3
```

Total: 10 Toffolis (gates 1–4 and 8–13) + 11 CNOTs (gates 5–7, 14–17, 18,
19–21). That's **21 gate operations**, with Toffoli:CNOT:NOT = 10:11:0.

**Correction to Section 3 pseudocode**. I had step 4 looping `for i in 2:W`.
That is wrong. The correct loop is `for i in 1:W`. I likewise had step 5b
correct (`for i in 2:W`) but step 5a is just `Z[1] ⊕= a[1]`.

The fixed pseudocode for steps 4 and 5:

```julia
# ---- Step 4: Z[i] ⊕= B[i]  for 0 ≤ i < n  (paper 0-based) -> 1-based 1..W
for i in 1:W
    push!(gates, CNOTGate(b[i], Z[i]))
end

# ---- Step 5a: Z[1] ⊕= a[1]   (paper: Z[0] ⊕= A[0])
push!(gates, CNOTGate(a[1], Z[1]))

# ---- Step 5b: B[i] ⊕= A[i] for 1 ≤ i < n  (undo step 2; 1-based 2..W)
for i in 2:W
    push!(gates, CNOTGate(a[i], b[i]))
end
```

(The CNOT count is still `3W - 1`: W for step 4, 1 for step 5a, W−1 for
step 5b, W−1 for step 2. Total = 3W − 1. ✓)

### Final W=4 verification (bit algebra)

Pick inputs `a = 0b1011 = 11` (`a_0=1, a_1=1, a_2=0, a_3=1`),
`b = 0b0111 = 7`. Sum = 18 = 0b10010. Z should become
`Z = (s_0, s_1, s_2, s_3, c_4) = (0, 1, 0, 0, 1)` — i.e. Z[1]=0, Z[2]=1,
Z[3]=0, Z[4]=0, Z[5]=1.

Full bit-by-bit trace (verified against the gate sequence above):

- After step 1: `Z = (0, a₀b₀, a₁b₁, a₂b₂, a₃b₃) = (0, 1, 1, 0, 0)`
- After step 2: `b = (1, 0, 1, 1)`
  (b[1] unchanged; b[2]=1⊕1=0; b[3]=1⊕0=1; b[4]=0⊕1=1)
- After gate 8 (P-round t=1 m=1): `X[1] = b[3]·b[4] = 1·1 = 1`
- After gates 9, 10 (G-round t=1): both Toffolis fire-or-no-fire:
  gate 9 Z[3] ⊕= Z[2]·b[2] = 1·0 = 0, no change. Gate 10 Z[5] ⊕= Z[4]·b[4] = 0·1 = 0,
  no change. `Z = (0, 1, 1, 0, 0)`.
- After gate 11 (G-round t=2): Z[5] ⊕= Z[3]·X[1] = 1·1 = 1. `Z = (0, 1, 1, 0, 1)`.
  Z[5] now holds `c_4 = 1`. ✓
- After gate 12 (C-round t=1 m=1): Z[4] ⊕= Z[3]·b[3] = 1·1 = 1. `Z = (0, 1, 1, 1, 1)`.
  Z[4] now holds `c_3 = 1`. ✓
- After gate 13 (P⁻¹): X[1] ⊕= b[3]·b[4] = 1·1 = 1, so X[1] = 0. ✓ ancilla clean.
- End of step 3: `Z = (0, c_1, c_2, c_3, c_4) = (0, 1, 1, 1, 1)`, `b = (1, 0, 1, 1)`,
  `X[1] = 0`.
- After step 4 (gates 14–17): Z[i] ⊕= b[i] for i=1..4 → `Z = (1, 1, 0, 0, 1)`.
- After step 5a (gate 18): Z[1] ⊕= a[1] = 1 → Z[1] = 0. `Z = (0, 1, 0, 0, 1)`.
- After step 5b (gates 19–21): b[i] ⊕= a[i] for i=2..4 → `b = (1, 1, 1, 0)`
  (restored to original). ✓

Final `Z = (0, 1, 0, 0, 1)`, i.e. `(s_0, s_1, s_2, s_3, c_4) = (0,1,0,0,1)`.
Read MSB-first this is binary `10010 = 18 = 11 + 7`. ✓ Ancilla zero, inputs
restored. Circuit is correct for this input; the test plan (§7) generalises
to all 2^(2W) = 256 pairs.

## Section 6 — Edge cases

### W = 1

Single bit. `logW = 0`, `w(W) = 1`, `n_anc = 1 - 1 - 0 = 0`. No P-rounds,
no G-rounds beyond the base, no C-rounds. The formulas degenerate
(paper explicitly says "for n ≤ 3, expression (5) overcounts the depth,
since there are no P-rounds"). **We fall back to `lower_add!`** — it's
2 gates total (CNOT + CNOT + CNOT), cheaper than any QCLA setup overhead.

### W = 2

`logW = 1`, `w(W) = 1`, `n_anc = 0`. Still no internal P_t storage
(P-rounds only run for `t=1..logW-1 = 1..0 = ∅`). Only the base-generate,
G-rounds (t=1, m=0), C-rounds, then sum-patching. Works in principle but
gate count is `5·2 - 3 - 3 - 1 = 3` Toffolis + `5` CNOTs = 8 gates,
versus ripple's `2·(W-1) = 2` Toffolis + `3W = 6` CNOTs = 8 gates.
Tie-ish, but QCLA adds an extra ~5 gates of "fixed overhead" (steps 1/2/5
that ripple folds into the carry loop). **We fall back to `lower_add!`.**

### W = 3

`logW = 1`, `w(W) = 2`, `n_anc = 3 - 2 - 1 = 0`. Similar to W=2.
Paper formula gives `5·3 - 6 - 3 - 1 = 5` Toffolis, which beats ripple's
`2·(W-1) = 4` only at W≥5. **We fall back to `lower_add!`.**

### Summary of small-W behaviour

```julia
if W < 4
    return lower_add!(gates, wa, a, b, W)
end
```

This keeps QCLA's promise of "log-depth adder" honest at all widths: for
W<4 we use the adder that is actually cheaper.

### Large W (W > 64 and non-power-of-2)

The formulas use `⌊log₂ W⌋` and `w(W)` — both well-defined integers for
any positive W. Non-power-of-2 widths (e.g. W=12) introduce irregular
`P_t` sizes (e.g. for W=12: `⌊12/2⌋=6` at t=1, `⌊12/4⌋=3` at t=2,
`⌊12/8⌋=1` at t=3). The pseudocode's `for m in 1:(div(W, 1<<t) - 1)` handles
this correctly without special-casing. **We assert** at the top of each
round that the integer arithmetic gives consistent counts (principle 1:
fail loud). If `n_anc` doesn't match the actual P_t slots allocated, we
error out with a clear message naming W, logW, w(W), and the mismatched
counts.

### Width boundary `W = 2^k` (exact powers of 2)

These are the paper's "nice" cases where `w(W) = 1` and the formulas
simplify. No special handling; just happens to hit the minimum of the
formulas. Good for regression baselines — use W=4, W=8, W=16, W=32 as
pinned gate counts.

## Section 7 — Test plan

### 7.1 Correctness tests

File: `test/test_qcla.jl`. For each width in `{4, 5, 6, 7, 8, 12, 16}`:

1. Build a stub: `g = ReversibleGate[]; wa = WireAllocator();`
   `a = allocate!(wa, W); b = allocate!(wa, W);`
   `Z = lower_add_qcla!(g, wa, a, b, W);`
2. Wrap in a `ReversibleCircuit` with `a`/`b`/`Z` declared as input/output.
3. For small widths (W ≤ 8), run **all 2^(2W) input pairs** through
   `simulate()` and assert `sum (low W) == Z low W` and `carry == Z top`.
4. For W ≥ 12, test ≥ 10,000 random pairs plus the edge cases:
   `(0, 0)`, `(2^W - 1, 0)`, `(2^W - 1, 1)`, `(2^W - 1, 2^W - 1)`,
   `(2^(W-1), 2^(W-1))`, random high-popcount values.
5. `verify_reversibility(circuit, a_bits, b_bits)` on every test input —
   confirms X ancillae return to zero. This is the CLAUDE.md principle #4
   gate.

### 7.2 Gate-count regression pins

These go in `test/test_gate_count_regression.jl`:

```julia
@testset "QCLA gate counts" begin
    for (W, exp_toffoli, exp_cnot, exp_anc) in [
        (4,  10, 11, 1),
        (5,  16, 14, 2),      # 5*5 - 3*2 - 3*2 - 1 = 12? recheck
        (8,  27, 23, 4),
        (16, 64, 47, 11),
        (32, 141, 95, 26),
        (64, 298, 191, 57),
    ]
        g = ReversibleGate[]; wa = WireAllocator()
        a = allocate!(wa, W); b = allocate!(wa, W)
        lower_add_qcla!(g, wa, a, b, W)
        t = count(x -> x isa ToffoliGate, g)
        c = count(x -> x isa CNOTGate, g)
        @test t == exp_toffoli
        @test c == exp_cnot
        # anc = total new wires minus (W+1 for Z) minus 0 NOTs
        # (we can read this off wire_count(wa) - 2W)
    end
end
```

Note: the W=5 row is load-bearing — it catches the non-power-of-2 case.
Formula: `5·5 - 3·w(5) - 3·⌊log 5⌋ - 1 = 25 - 6 - 3 - 1 = 15`. CNOT = 3·5-1 = 14.
Ancillae = 5 - w(5) - 2 = 5 - 2 - 2 = 1.

Let me redo that table with the right numbers:

| W  | w(W) | ⌊log W⌋ | Toffoli (5W-3w-3log-1) | CNOT (3W-1) | anc (W-w-log) |
|----|------|---------|------------------------|-------------|---------------|
| 4  | 1    | 2       | 10                     | 11          | 1             |
| 5  | 2    | 2       | 12                     | 14          | 1             |
| 6  | 2    | 2       | 17                     | 17          | 2             |
| 7  | 3    | 2       | 19                     | 20          | 2             |
| 8  | 1    | 3       | 27                     | 23          | 4             |
| 16 | 1    | 4       | 64                     | 47          | 11            |
| 32 | 1    | 5       | 141                    | 95          | 26            |
| 64 | 1    | 6       | 298                    | 191         | 57            |

These are the regression pins. If any of them changes, investigate.

### 7.3 Bennett-wrap integration test

Wrap `lower_add_qcla!` via the Bennett construction and confirm:

- `verify_reversibility` passes for all 256 inputs at W=4 (both 4-bit halves).
- Ancilla count post-Bennett = `n_anc + (W+1)` pre-wrap, × 2 for
  the reverse pass, plus the W+1 output copy register. (Exact number
  depends on the Bennett wrapper's ancilla strategy.)

### 7.4 Differential test against ripple

For W in {4, 8, 16}, build two circuits — `lower_add!` and
`lower_add_qcla!` — and compare their outputs on 10,000 random inputs.
They must agree bit-for-bit.

### 7.5 Fallback test

- `lower_add_qcla!` with W in {1, 2, 3} must produce **exactly** the same
  gate list as `lower_add!` with the same W. Verify with
  `@test g_qcla == g_ripple`.

### 7.6 LLVM integration (future, not in this PRD)

Plumbing QCLA into `lower.jl`'s `lower_instruction!` handler for `add`
instructions is a separate change. For now, QCLA is a library function in
`adder.jl` exposed alongside `lower_add!` and `lower_add_cuccaro!`, and the
compile entry point picks ripple by default. A `compile_options` struct
with an `:adder => :qcla` key is the cleanest plumbing point, but that's
out of scope for this proposer doc.

## Appendix — deviations from the paper

1. **0-based → 1-based**. Paper arrays are 0-based; we translate at the
   boundaries (wire assignment and gate emission). Internal index
   arithmetic stays paper-native.
2. **No schedule overlap**. Paper achieves depth `⌊log n⌋ + ⌊log(n/3)⌋ + 7`
   by overlapping G-round t+1 with P-round t+2. Bennett.jl emits gates in
   a linear list; our "depth" is the list length unless a downstream
   scheduler reorders. This does not affect correctness, just wall-clock.
3. **P⁻¹ after C-rounds**. Paper overlaps P⁻¹ with C. We emit
   P⁻¹ strictly after C. No correctness change.
4. **Out-of-place only**. In-place variant (Section 4.2) deferred.
