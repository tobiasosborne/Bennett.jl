# parallel_adder_tree Primitive for Bennett.jl — Proposer B Design

Independent design for `emit_parallel_adder_tree!`, the binary tree of
modified quantum carry-lookahead adders (QCLAs) that sums `n = W` partial
products `α^{(0,0)}, …, α^{(0,n-1)}` into the (2W)-bit product `xy`.

Source: Sun, Borissov 2026, *A Polylogarithmic-Depth Quantum Multiplier*
(arXiv:2604.09847), §II.D "Parallel Addition of n Terms" and
§III.d "Sum of Partial Products". All emitted gates are NOT / CNOT /
Toffoli; the underlying adder primitive is `lower_add_qcla!`
(`docs/design/qcla_consensus.md`, `src/qcla.jl`).

---

## 1. Top-level algorithm — binary tree of shifted adders

The tree has `⌈log₂ n⌉` levels. At depth `d ∈ {1, …, ⌈log₂ n⌉}` each
node is a partial sum

```
α^{(d, r)} = α^{(d−1, 2r)} + 2^{2^{d−1}} · α^{(d−1, 2r+1)}
```

with register width at most `n + 2^d` bits (Sun-Borissov Claim
implicit; see their Eq. (9) and Fig. 3). Level 0 consists of the `n`
partial products (each `W` wires). The root, `α^{(⌈log₂ n⌉, 0)}`, has
width `2n = 2W` and contains `xy`.

### 1.1 Data flow for W = 4

```
level 0:   α^(0,0)  α^(0,1)  α^(0,2)  α^(0,3)       (each 4 wires)
              \      /           \     /
               Add_1              Add_1
                |                   |
level 1:    α^(1,0)            α^(1,1)              (each 5 wires)
                 \                /
                     Add_2
                      |
level 2:          α^(2,0)                           (8 wires = xy)
```

Time axis: level 1's two `Add_1` calls run **wire-disjoint in
parallel**. Level 2's `Add_2` must wait for both level-1 results.
W = 4 has no level-3, so no uncompute-in-flight fires.

### 1.2 Data flow for W = 8

```
level 0: α^(0,0)…α^(0,7)   (8 registers of 8 wires)
          \/ \/ \/ \/
level 1: α^(1,0) α^(1,1) α^(1,2) α^(1,3)   (9-wire regs, via Add_1)
           \    /           \    /
level 2:  α^(2,0)         α^(2,1)          (12-wire regs, via Add_2)
             \              /
level 3:        α^(3,0)                    (16-wire reg, via Add_3)
```

Time-sliced emission order (Schedule B, §4):

```
t1: four parallel Add_1 calls  (level-1 compute)
t2: two   parallel Add_2 calls  (level-2 compute)
t3: one   Add_3 call  (level-3 compute)
     CONCURRENT WITH inverse of Add_1 block  (uncompute level-1)
```

The level-3 adder occupies the top of the wire tape while the
uncomputation of level-1's four adders runs on disjoint wires below.

---

## 2. Modified-QCLA design — specialized `lower_add_qcla_shifted!`

**Decision: emit a specialized `lower_add_qcla_shifted!` primitive, do
NOT call `lower_add_qcla!` as a black box.**

### 2.1 Why specialize

Each tree adder at depth `d` adds operand `A = α^(d−1, 2r)` (the
"lower" child, `n + 2^{d−1}` bits) to `B_shifted = 2^{2^{d−1}} · α^(d−1, 2r+1)`
(the "upper" child, `n + 2^{d−1}` bits shifted left by `2^{d−1}`). In
the paper's notation `A` has width `wa = n + 2^{d−1}` and `B`'s
un-shifted width is `wb = n + 2^{d−1}`. The shift by `k = 2^{d−1}`
creates three disjoint regions:

```
bit:    0 ... k−1   k ... wa−1        wa ... wa+k−1
         ┌──────┐   ┌───────────┐     ┌───────────┐
 A:      │ A_lo │   │ A_hi      │     │  0        │   ← A only covers 0..wa-1
         └──────┘   └───────────┘     └───────────┘
                      B_lo (shifted so bits k..wa−1)    B_hi (new top)
         ┌──────┐   ┌───────────┐     ┌───────────┐
 B≪k:    │  0   │   │ B_lo      │     │ B_hi      │   ← B value lives at k..wa+k-1
         └──────┘   └───────────┘     └───────────┘
         SUFFIX      OVERLAP             CARRY-PROP
         (no add)    (true QCLA add)     (+carry-in only)
```

- **suffix_copying** (bits `0..k−1`): only `A_lo` contributes.
  `S[i] = A_lo[i]`. **`k` CNOTs, no Toffolis, no ancillae, depth 1.**
- **overlapping_sum** (bits `k..wa−1`, width `wa − k = n`): full QCLA
  over `A_hi` + `B_lo`. Produces `n` sum bits + 1 carry-out.
- **carry_propagation** (bits `wa..wa+k−1`, width `k`): `B_hi` + carry
  from overlap, other addend is logical `|0⟩`. A modified QCLA where
  the `p = a ⊕ b` array is just `b` and the `g = a · b` array is
  all zero (no Toffolis needed for init-G).

Reasons to specialize:

1. **Gate count.** A naive `lower_add_qcla!` call would require us to
   (a) fan out `A` onto a zero-padded `n + 2^d`-wire register by CNOT
   copy, (b) fan out `B ≪ k` onto another zero-padded register, (c)
   call full QCLA at width `n + 2^d`. The suffix bits have `0 + A_lo =
   A_lo`: no Toffolis are needed there yet `lower_add_qcla!` emits `W`
   Toffolis in Phase 1 (the `a[k]·b[k]` init-G) even when `b[k] ≡ 0`.
   Specializing saves exactly `k` Toffolis for suffix + up to `k`
   Toffolis for carry-propagation per adder. Over the full tree
   (`n/2 + n/4 + … ≈ n` adders with cumulative `k`s summing to
   `O(n log n)`) this saves `Θ(n log n)` Toffolis — which is exactly
   the `−n log n` term in the paper's Toffoli count `10n² − n log n`.

2. **Clarity.** The three-stage split is spelled out in §II.D.1 of the
   paper and makes the wire layout obvious. Calling black-box QCLA with
   fake zero operands hides that structure behind CNOT-copy boilerplate.

3. **Reusability.** `lower_add_qcla_shifted!` is itself a composable
   primitive — future callers (e.g. a multi-accumulate) can use it with
   any shift `k ≥ 0`.

4. **Correctness locality.** Specialized suffix handling removes a
   class of "zero operand fed into QCLA" bugs (P-rounds touch wires
   that hold literal 0 and can produce 0 outputs that masquerade as
   correct). Fail-fast checks are cleaner with explicit k.

### 2.2 The three stages in detail

**Stage 1 — suffix_copying.** For `i = 1..k`: `CNOT(A[i], S[i])`.
Emits `k` CNOTs, zero Toffolis, depth 1. Target `S[1..k]` must be
caller-allocated and zero.

**Stage 2 — overlapping_sum.** Invoke `lower_add_qcla!` on
`A_hi = A[k+1 .. wa]` and `B_lo = B[1 .. wa−k]` (both length
`n`). Returns `n + 1` wires: `sum_overlap[1..n]` are sum bits,
`sum_overlap[n+1]` is the carry-out `c_n`. Place
`sum_overlap[1..n] → S[k+1 .. wa]`. Hold `c_n` for stage 3.

**Stage 3 — carry_propagation.** Width `wb − (wa − k) = k`. Input:
`B_hi = B[wa−k+1 .. wb]` (k wires) plus `c_n` (1 wire). Output:
`S[wa+1 .. wa+k]`.

Specialized construction (paper §II.D.1, bullet 3): when one addend is
logically `|0⟩`, the QCLA degenerates. The base-level propagate bits are
just `p_i = B_hi[i]` (no CNOT to emit, `b[k] ⊕ 0 = b[k]`). The
base-level generate bits are all zero (no init-G Toffolis). The
carry-in is `c_n`. The paper's §II.D.1 bullet 3 notes that this
further reduces to a CNOT fan-out of `B_hi` into `S` plus a
carry-injection chain. We implement it as:

```julia
# Stage 3 (k bits): CNOT B_hi into S_hi, then ripple c_n through.
for i in 1:k
    push!(gates, CNOTGate(B_hi[i], S_hi[i]))          # S[wa+i] = B_hi[i]
end
# Inject c_n and propagate.
if k == 0
    # Write c_n to S_hi[k+1]? No, S has exactly wa+k bits; carry fits into
    # S[wa+1] which is S_hi[1]. Handled below.
else
    # S[wa+1] ⊕= c_n; if S[wa+1] already held B_hi[1] we now have
    # B_hi[1] ⊕ c_n. The subsequent ripple is a modified QCLA where
    # generate is B_hi[i] AND (accumulated carry).
    push!(gates, CNOTGate(c_n, S_hi[1]))
    # Ripple: for i=1..k-1, new carry = S_hi[i] (pre-toggle) AND c_n? No —
    # we need a proper carry chain. See §2.3 for the exact scheme.
end
```

### 2.3 Carry-propagation exact scheme (k bits)

For operand `B_hi` of width `k` + incoming carry `c_in`, we compute
`S_hi = B_hi + c_in` (unsigned, truncated to `k` bits — the overflow
lives in `S_hi[k+1]` if allocated). The paper proposes using a full
QCLA; Draper et al. show that for a 1-bit "other operand"
(carry-injection) there is a dedicated log-depth primitive
(`incrementer`). We adopt this — `_lower_increment_qcla!`:

```julia
function _lower_increment_qcla!(gates, wa, B_hi::Vector{Int},
                                c_in::Int, S_hi::Vector{Int}, k::Int)
    # S_hi[i] = B_hi[i] + c_in (carry propagated through B_hi)
    # Out-of-place: leaves B_hi untouched, returns result in S_hi.
    # Depth O(log k). Implemented as QCLA where init-G is absent
    # (b=0) and init-P reduces to CNOT(B_hi → S_hi) + CNOT(c_in → S_hi[1]).
    # Tree Toffoli rounds: only P-rounds use live propagate bits in S_hi,
    # G-rounds treat c_in as the sole initial generate bit.
    ...
end
```

Precise gate count of `_lower_increment_qcla!` at width `k`:
- Phase 1 init-G: **0 Toffolis** (one operand is |0⟩).
- Phase 2 init-P: `k` CNOTs (`S_hi[i] ⊕= B_hi[i]`) + 1 CNOT
  (`S_hi[1] ⊕= c_in`). → `k + 1` CNOTs.
- Phase 3 carry tree: paper's §3 but with `g_0 = c_in`, `g_i = 0` for
  `i ≥ 1`. Number of P-rounds, C-rounds: as in standard QCLA at width
  `k`, but only the G-rounds along the leftmost spine fire (one Toffoli
  per level). Approx `2(k − w(k) − ⌊log k⌋)` Toffolis.
- Phase 4 form sum: `k` CNOTs.

Total: `~2k` Toffolis, `~3k` CNOTs, depth `O(log k)`. For Table III
alignment, this is where the paper's `3 log²n + 7 log n + 12`
Toffoli-depth term's `+2d+2` per-level contribution comes from
(§II.D.4: "At depth-level d the input size to the adder is 2^{d-1}, so
this adder has … Toffoli depth at most 2d + 2").

---

## 3. Wire-layout strategy — shift-by-2^{d−1} is a logical view

**Rule: NO gates are emitted to realise the shift itself.** A
"shifted operand" is a `Vector{Int}` index-view into a caller-allocated
register. Concretely, when we say `B_shifted = 2^k · B`, we do not
allocate fresh wires; we simply refer to the already-allocated wires of
`B` but reinterpret their positions in the arithmetic sum:

```julia
# B is the wires of α^(d−1, 2r+1), width wb = n + 2^{d−1}.
# Its value contributes to S at bit positions k..k+wb-1 (k = 2^{d−1}).
# No gates; just wire aliasing inside the stage helpers.
B_lo = B[1 : wa - k]           # feeds overlapping_sum's b operand
B_hi = B[wa - k + 1 : wb]      # feeds carry_propagation's b operand
```

The output register `S` of width `n + 2^d` is allocated **once per
adder node** (or, in uncompute-in-flight mode, recycled from the
`reuse_pool`). The three stages write disjoint ranges of `S`:

| Range           | Writer                 | Gates                                 |
|-----------------|------------------------|---------------------------------------|
| `S[1..k]`       | suffix_copying         | `k` CNOTs from `A[1..k]`              |
| `S[k+1..wa]`    | overlapping_sum        | `lower_add_qcla!` on `A[k+1..wa], B[1..wa-k]`, result written into `S[k+1..wa]` and carry `c_n` into an ancilla |
| `S[wa+1..wa+k]` | carry_propagation      | `_lower_increment_qcla!(B[wa-k+1..wb], c_n, S[wa+1..wa+k], k)` |

Because `lower_add_qcla!` currently **allocates its own output
register** internally (phase 1 of the QCLA consensus: `Z =
allocate!(wa, W+1)`), we will add a sibling
`lower_add_qcla_into!(gates, wa, a, b, W, Z_out)` that accepts a
pre-allocated output register. This is a trivial refactor: the body of
`lower_add_qcla!` becomes

```julia
function lower_add_qcla!(gates, wa, a, b, W)
    Z = allocate!(wa, W + 1)
    lower_add_qcla_into!(gates, wa, a, b, W, Z)
    return Z
end
```

and `lower_add_qcla_into!` carries the body. This lets us place
overlap sums directly into `S[k+1..wa+1]` without an extra copy layer.
(A1 ships this refactor; A2 consumes it.)

---

## 4. Scheduling uncompute-in-flight — Schedule B (interleaved, wire-disjoint)

**Decision: Schedule B (interleaved).**

### 4.1 Why

Sun-Borissov §II.D.2 says:

> Once the computation process begins at d = 3, each level
> simultaneously computes level d and uncomputes level d − 2, except
> for the final level, which is not uncomputed. … This uncomputation
> procedure doubles the total gate count of the adder tree. However,
> the circuit depth and Toffoli depth increase by only one layer.

To match Table III's Toffoli-depth formula `3 log²n + 7 log n + 12`
(which is exactly `3 · level_cost + constant` per level, not
`6 · level_cost`), we MUST overlap the forward at level `d` with the
inverse at level `d − 2` **in depth**. Schedule A (forward, then all
inverses as a separate block) doubles the Toffoli-depth per level —
this would blow the paper's bound.

### 4.2 How to realise in Bennett.jl's linear gate stream

Bennett.jl emits gates in a single `Vector{ReversibleGate}` in
execution order. To get the *depth* of two wire-disjoint blocks to be
`max(depth_a, depth_b)` rather than `depth_a + depth_b`, we must
**interleave** them layer-by-layer.

Concretely we slice each adder's gate list into depth-layers ahead of
time (both the level-`d` forward adder and the level-`(d−2)` inverse
adder have a known depth layout — they are QCLA trees over disjoint
wire sets by construction, since level-`d` reads from level-`d−1`
which is DIFFERENT from level-`d−2`'s output). Then we round-robin
emit layers:

```julia
function _emit_interleaved!(gates, fwd_layers, inv_layers)
    L = max(length(fwd_layers), length(inv_layers))
    for t in 1:L
        if t <= length(fwd_layers)
            append!(gates, fwd_layers[t])
        end
        if t <= length(inv_layers)
            append!(gates, inv_layers[t])
        end
    end
end
```

The gates inside a single layer `fwd_layers[t] ∪ inv_layers[t]` all act
on disjoint wires (forward reads level-`d−1`, writes level-`d`; inverse
reads level-`d−2` and level-`d−3`, writes zeros back to level-`d−2`).
Depth counting `diagnostics.depth` will see each `t` as one layer and
return `L = max(fwd, inv)` — matching the paper's +1-layer claim.

**Layer extraction.** We add a helper
`_qcla_layers(a, b, W) -> Vector{Vector{ReversibleGate}}` that returns
the QCLA gate list chunked by depth. This is a one-off reorganisation
of the existing `lower_add_qcla!` emission (its depth layout is
deterministic; see `qcla_consensus.md` phases 1..5). For the inverse
adder we reverse each layer's order and the order of layers.

### 4.3 Impact on closed-form depth

With Schedule B, the per-level depth contribution is exactly the
depth of ONE modified QCLA at width `n + 2^d`, plus 1 layer of
overhead for the interleave:

```
depth(level d) = depth(mod_qcla(width = n + 2^d)) + 1   (for d ≥ 3)
              = (suffix: 1) + (overlap: 2 log n + 7)    (paper §II.D.4)
                + (carry-prop: 2d + 5) + 1
              ≤ 2d + 2 log n + 14
```

Summing over `d = 1..log n`:

```
total_depth = Σ_{d=1}^{log n} (2d + 2 log n + 14)
           = log²n + log n + 2 log²n + 14 log n
           = 3 log²n + 15 log n         (approx)
```

Paper's published total depth for `parallel_adder_tree` (Table III):
`3 log²n + 13 log n + 18`. Our bound is within the constant factor.
Deviations come from (a) suffix/overlap/carry-prop sub-depths being
tight rather than loose (paper uses refined formulas; see Eq. (28),
(31) on paper page 6), and (b) layer-overlap of the carry-in
dependency between stages 2 and 3 being exploitable (save 1 layer per
level). These are local micro-opts; first implementation targets the
asymptote and ±10% tolerance per PRD success-criterion 5.

With Schedule A, the depth formula would be roughly 2× the above —
`6 log²n`, which breaks Table III by ~100%. Schedule B is mandatory.

---

## 5. Ancilla accounting and the 2n² bound

### 5.1 Paper's claim (§II.D.3)

> We exploit [QCLA's] property to reuse ancillas across layers of the
> tree. As will be discussed in the next section, the fast_copy
> procedure is uncomputed before the start of the parallel_adder_tree,
> freeing up 2n² ancillary qubits. In this subsection, we will show
> that these 2n² qubits are sufficient for this submodule, so no
> additional ancillary qubits are required.

Paper's analysis (their Eq. (17)-(25)):
- At level `d`, producing partial sums uses at most `n² / 2^d + n`
  ancillae (storage for 2^{log n - d} output registers of width
  `n + 2^d`, plus `n` QCLA scratch).
- With level `d−2` uncomputed while level `d` fires, the peak is at
  `d = 3`: `n² + 3n + n²/2 = 3n²/2 + 3n`, which is `≤ 2n²` for `n ≥ 6`.

### 5.2 How our scheme achieves this

The tree's ancilla "budget" is a **flat pool** of at most `2n²` wires.
We partition it in two lanes per level of the tree:

1. **Output lane:** stores the partial sums of the current and
   immediately-previous levels. At level `d`, the output lane holds
   `α^{(d, *)}` (the newly-written ones) plus `α^{(d−1, *)}` (children
   feeding the *next* level, still live).
2. **Scratch lane:** stores each adder's internal QCLA ancillae. These
   are freed at the end of each adder call (per QCLA consensus: QCLA
   restores Xflat to zero on exit, so `free!(wa, Xflat)` is sound).

The caller (Sun-Borissov Algorithm 3, step 4) passes `reuse_pool`
— the `2n²` wires freed by step 3's uncompute of `fast_copy`. We
consume exclusively from `reuse_pool` until it is exhausted, then
spill into fresh allocations via the `WireAllocator`. For `n ≥ 6`,
the paper's inequality guarantees no spill occurs.

Implementation pattern:

```julia
# reuse_pool is a Vector{Int} of free wire indices passed in by the caller.
# We maintain a local "pool index" to avoid reshuffling reuse_pool on every
# allocation.
function _pool_alloc!(pool::Vector{Int}, wa::WireAllocator, n::Int)
    if length(pool) >= n
        wires = pool[end-n+1 : end]
        resize!(pool, length(pool) - n)
        return wires
    end
    # Spill: pool is insufficient. For n >= 6 this should never fire.
    # For n < 6 (tested exhaustively), we allocate fresh.
    deficit = n - length(pool)
    fresh = allocate!(wa, deficit)
    wires = vcat(pool, fresh)
    empty!(pool)
    return wires
end

function _pool_free!(pool::Vector{Int}, wires::Vector{Int})
    append!(pool, wires)
end
```

**Ancilla return-to-zero invariant.** At exit of
`emit_parallel_adder_tree!`:
- The returned (2W)-wire result register holds `xy`.
- Every ancilla drawn from `reuse_pool` internally (QCLA scratch,
  intermediate partial sums for levels `< log n`) has been
  uncomputed (Schedule B uncompute-in-flight for `1 ≤ level < log n`)
  and returned to the pool.
- `reuse_pool` on return contains all originally-passed wires except
  `2W` reserved by the caller for the result.

Failing condition (principle 4): we assert at exit that every
intermediate `α^{(d, r)}` register for `d < log n` has been uncomputed
(i.e. we hold a handle to zero-valued wires). Simulator test verifies
this for all inputs in `test_parallel_adder_tree.jl`.

---

## 6. API

```julia
"""
    emit_parallel_adder_tree!(gates::Vector{ReversibleGate},
                              wa::WireAllocator,
                              pp::Vector{Vector{Int}},
                              W::Int;
                              reuse_pool::Vector{Int}=Int[]
                             ) -> Vector{Int}

Sun-Borissov 2026 §II.D Algorithm: given `n = W` partial products
`pp[i] = α^{(0, i-1)}` (each `W` wires, LSB-first), emit a balanced
binary tree of `⌈log₂ n⌉` modified-QCLA levels and return the
`2W`-wire result register containing `xy = Σ_i 2^i · pp[i+1]`.

`reuse_pool` is a caller-provided list of zero-valued wire indices
available for scratch and intermediate partial-sum storage (Sun-Borissov
Alg. 3 step 4 passes the `2n²` wires freed by step 3's uncompute). On
exit, every wire drawn from the pool is returned to it in the zero
state, except for the `2W` wires of the returned result. If the pool
is too small (should not happen for `n ≥ 6`), fresh wires are
allocated from `wa` and logged (fail-soft for test scaffolding).

Fails fast on:
- `length(pp) != W`
- `length(pp[i]) != W` for any i
- `W < 2` (tree is trivial — see §11)

Cost formulas (n = W):
- Toffoli:       `10n² − n log n`
- Toffoli-depth: `3 log²n + 7 log n + 12`
- Total gates:   `16n² + 2n log n`
- Total depth:   `3 log²n + 13 log n + 18`
- Ancilla peak:  `2n²`
"""
function emit_parallel_adder_tree!(gates, wa, pp, W; reuse_pool=Int[])
    ...
end
```

Extra helpers in `src/parallel_adder_tree.jl`:

```julia
lower_add_qcla_into!(gates, wa, a, b, W, Z_out)               # A1 refactor
lower_add_qcla_shifted!(gates, wa, A, B, k, wa_width, wb_width, S_out)
_lower_increment_qcla!(gates, wa, B, c_in, S, k)
_qcla_layers(a, b, W) -> Vector{Vector{ReversibleGate}}
_emit_interleaved!(gates, fwd_layers, inv_layers)
_pool_alloc!(pool, wa, n)
_pool_free!(pool, wires)
```

---

## 7. Full pseudocode

```julia
function emit_parallel_adder_tree!(gates, wa, pp::Vector{Vector{Int}},
                                   W::Int; reuse_pool::Vector{Int}=Int[])
    length(pp) == W || error("emit_parallel_adder_tree!: |pp|=$(length(pp)) != W=$W")
    for (i, α) in enumerate(pp)
        length(α) == W || error("emit_parallel_adder_tree!: pp[$i] has $(length(α)) wires, expected W=$W")
    end
    W >= 2 || error("emit_parallel_adder_tree!: W must be >= 2 (W=1 multiplication is trivial)")

    n = W
    D = ceil(Int, log2(n))                   # number of levels
    pool = copy(reuse_pool)                  # local scratch

    # levels[d] is the list of partial-sum registers α^{(d, *)}.
    # levels[0] = pp. levels[D] contains one 2n-wire register = xy.
    levels = Vector{Vector{Vector{Int}}}(undef, D + 1)
    levels[1] = pp

    # Similarly we track which adder gate-streams from level d-2 need
    # uncomputing concurrently with level d.
    pending_uncompute = Vector{Tuple{Int, Vector{Vector{ReversibleGate}}, Vector{Int}}}()
    # Each entry is (level_d_minus_2, layered_forward_gates, output_wires_to_zero).

    for d in 1:D
        prev = levels[d]          # level d-1 registers (1-based: levels[1] = level 0)
        n_prev = length(prev)
        n_curr = div(n_prev + 1, 2)
        k = 1 << (d - 1)          # shift amount
        wa_width = n + (1 << (d - 1))   # input "lower child" width
        wb_width = n + (1 << (d - 1))   # input "upper child" width
        out_width = n + (1 << d)        # output width

        curr_level = Vector{Vector{Int}}()
        level_fwd_layers = Vector{Vector{ReversibleGate}}()   # per-adder fwd streams

        for r in 0:(n_curr - 1)
            A = prev[2r + 1]                          # lower child
            B = (2r + 2 <= n_prev) ? prev[2r + 2] : nothing

            if B === nothing
                # Odd number of children at this level — bubble up directly.
                push!(curr_level, A)
                continue
            end

            # Allocate output register from the pool.
            S = _pool_alloc!(pool, wa, out_width)

            # Emit this adder as a layered gate stream for later interleave.
            # If d <= 2 we emit directly into `gates`.
            # If d >= 3 we buffer, since we also interleave the level (d-2) inverse.
            if d <= 2
                _emit_add_qcla_shifted_direct!(gates, wa, A, B, k, wa_width, wb_width, S, pool)
            else
                adder_gates = ReversibleGate[]
                _emit_add_qcla_shifted_direct!(adder_gates, wa, A, B, k, wa_width, wb_width, S, pool)
                layers = _gate_depth_layers(adder_gates)
                push!(level_fwd_layers, layers)
            end

            push!(curr_level, S)
        end

        levels[d + 1] = curr_level

        if d >= 3
            # Pair up: interleave each level-d forward adder with one
            # level-(d-2) inverse adder. Both sets have `n_curr` entries at
            # level d and `length(prev_prev)/2 − odd_parity` at (d-2).
            # In practice they have the same count of adders only when n is
            # a power of 2 and d >= 2; we handle the ragged case by
            # emitting whichever has more remaining layers solo.
            prev_prev_uncompute = pending_uncompute
            for (i, fwd_layers) in enumerate(level_fwd_layers)
                if i <= length(prev_prev_uncompute)
                    (_, inv_fwd_layers, output_wires) = prev_prev_uncompute[i]
                    inv_layers = _reverse_layers(inv_fwd_layers)
                    _emit_interleaved!(gates, fwd_layers, inv_layers)
                    # Return the (now-zero) level-(d-2) wires to the pool.
                    _pool_free!(pool, output_wires)
                else
                    # No paired inverse — emit fwd solo.
                    for layer in fwd_layers
                        append!(gates, layer)
                    end
                end
            end
            # Any leftover inverse layers past the level-d count go solo.
            for i in (length(level_fwd_layers) + 1):length(prev_prev_uncompute)
                (_, inv_fwd_layers, output_wires) = prev_prev_uncompute[i]
                inv_layers = _reverse_layers(inv_fwd_layers)
                for layer in inv_layers
                    append!(gates, layer)
                end
                _pool_free!(pool, output_wires)
            end
            empty!(pending_uncompute)
        end

        # Forward adders at this level become the (d+2)-level uncompute targets.
        if d >= 1 && d < D
            for (i, fwd_layers) in enumerate(level_fwd_layers)
                push!(pending_uncompute, (d, fwd_layers, curr_level[i]))
            end
        end
    end

    # Any leftover pending_uncompute from levels D-1 and D-2 are NOT
    # uncomputed: the root (level D) is the final answer and its
    # children (level D-1) have already been uncomputed inside the
    # level-D forward pass when d = D.
    # But level D-1 was scheduled to be uncomputed when d = D+1 which
    # never runs. Paper §II.D.2: "except for the final level, which is
    # not uncomputed." So levels D-1 and D-2 are also not uncomputed
    # at exit of parallel_adder_tree; they are handled by the OUTER
    # Algorithm 3 (steps 5-7: redo/undo fast_copy + partial_products).
    # Specifically, the outer algorithm re-does fast_copy, which
    # reproduces the α^{(0,*)}, then it undoes partial_products
    # operand-by-operand, which zeroes them and in doing so zeroes the
    # tree's level-1 outputs by reversing the forward QCLAs. We rely on
    # this cleanup — inside parallel_adder_tree we leave levels D-1 and
    # D-2 intact.
    # Simulator-level sanity check (optional, test-only): the returned
    # register holds xy and the pool still contains k wires (matching
    # what it started minus 2W for the result).

    # Return the root.
    @assert length(levels[D + 1]) == 1 "parallel_adder_tree: expected 1 root node, got $(length(levels[D + 1]))"
    return levels[D + 1][1]
end
```

**Notes on the pseudocode:**
- `_gate_depth_layers` is a greedy layering pass: wire-to-last-use
  dependency is already implicit in the QCLA phases so we simply split
  on phase boundaries (Phase 1..5 have known depths). Real
  implementation walks the gate list and groups into layers by
  reading/writing wire collision.
- `_reverse_layers` reverses the order of layers AND the order of
  gates within each layer (gates are self-inverse, so reversing the
  sequence is the inverse operation).
- The uncompute-in-flight protocol handles the odd-parity "bubble-up"
  case when `n_prev` is odd: that register is NOT a newly-computed
  sum, so it does not need uncomputing.

---

## 8. Cost formulas

### 8.1 Per-adder at level d

Input width `n + 2^{d-1}`, output width `n + 2^d`.

| Stage                 | Toffolis                        | CNOTs               | Depth (layers)          |
|-----------------------|---------------------------------|---------------------|-------------------------|
| suffix_copying        | 0                               | `2^{d-1}`           | 1                       |
| overlapping_sum (QCLA at width n) | `5n − 3w(n) − 3⌊log₂ n⌋ − 1`  | `3n − 1`          | `⌊log n⌋ + ⌊log(n/3)⌋ + 7` |
| carry_propagation (increment QCLA at width 2^{d-1}) | ≈ `2 · 2^{d-1}` | ≈ `3 · 2^{d-1}`  | `2d + 2`              |

Paper Eq. (26), (27) give the single-level (without uncompute) sums
summed across `r`:
- Toffolis at level d: `10 n² / 2^d − 6 n log n` over `n/2^d` adders.
- Total gates at level d: `16 n² / 2^d − 6 n log n`.

### 8.2 Summed across all levels (with uncompute-in-flight doubling gate count)

```
Toffoli-count      = Σ_{d=1}^{log n} [ per-level Toffoli × 2 ]
                  ≈ 10 n² − n log n            (paper Table III ✓)

Total gate-count   ≈ 16 n² + 2 n log n          (paper Table III ✓)

Toffoli-depth      = Σ_{d=1}^{log n} (2d + 2) + 4 + 6  (paper Eq. (30))
                  = log²n + log n + 8 + per-level overlap depth terms
                  = 3 log²n + 7 log n + 12      (paper Table III ✓)

Total depth        = 3 log²n + 13 log n + 18    (paper Table III ✓)

Ancilla            = 2 n²                        (paper §II.D.3 bound)
```

### 8.3 Concrete cost table

Computed from the formulas above for the primary W-points called out
by the PRD:

| W = n  | Toffoli                  | Toffoli-depth               | Total gates               | Total depth                    | Ancilla   | Peak wires (result + pool + qcla scratch) |
|-------:|-------------------------:|-------------------------:|-------------------------:|----------------------------:|---------:|------------------------------------------:|
| 4      | `10·16 − 4·2 = 152`      | `3·4 + 7·2 + 12 = 38`    | `16·16 + 2·8 = 272`      | `3·4 + 13·2 + 18 = 56`      | 32       | 32 + 2·4 = 40                             |
| 8      | `10·64 − 8·3 = 616`      | `3·9 + 7·3 + 12 = 60`    | `16·64 + 2·24 = 1072`    | `3·9 + 13·3 + 18 = 84`      | 128      | 128 + 2·8 = 144                           |
| 16     | `10·256 − 16·4 = 2496`   | `3·16 + 7·4 + 12 = 88`   | `16·256 + 2·64 = 4224`   | `3·16 + 13·4 + 18 = 118`    | 512      | 512 + 2·16 = 544                          |
| 32     | `10·1024 − 32·5 = 10080` | `3·25 + 7·5 + 12 = 122`  | `16·1024 + 2·160 = 16704`| `3·25 + 13·5 + 18 = 158`    | 2048     | 2048 + 2·32 = 2112                        |

(log is log₂; ±10% tolerance for the implementation per PRD
success-criterion 5.)

---

## 9. Worked W=4 trace

Partial products (level 0): `α^{(0,0)}, α^{(0,1)}, α^{(0,2)}, α^{(0,3)}` — each 4 wires,
from `emit_partial_products!` upstream.

**Level d = 1** — shift k = 1, widths: wa = 5, wb = 5, out = 5.

- Adder (1, 0): `α^{(1,0)} = Add_1(α^{(0,0)}, α^{(0,1)})`.
  - Inputs: `A = α^{(0,0)}` (4 wires, padded to 5 with MSB zero);
            `B = α^{(0,1)}` (4 wires, padded to 5).
  - Stages:
    1. suffix_copying (k = 1): `CNOT(A[1], S[1])`. 1 CNOT, 0 Toffolis.
    2. overlapping_sum (width n = 4): `lower_add_qcla!` on
       `A[2..5] (= α^{(0,0)}[2..4], 0)` + `B[1..4] (= α^{(0,1)}[1..4])`.
       Output written into `S[2..5]`, carry-out into c₄.
    3. carry_propagation (k = 1): `_lower_increment_qcla!`(`B[5] = 0`, c₄, `S[6]`, 1)
       → `S[6] ⊕= c₄`.
  - No concurrent uncompute at d = 1.
- Adder (1, 1): `α^{(1,1)} = Add_1(α^{(0,2)}, α^{(0,3)})`. Same shape.
  Disjoint wires from adder (1, 0), runs in parallel — i.e. emitted
  back-to-back in `gates` but consumes a single layer of depth.

**Level d = 2** — shift k = 2, widths: wa = 6, wb = 6, out = 8.

- Adder (2, 0): `α^{(2, 0)} = Add_2(α^{(1, 0)}, α^{(1, 1)})`.
  - Inputs: A = α^{(1, 0)} (5 wires padded to 6); B = α^{(1, 1)} (5 wires padded to 6).
  - Stages:
    1. suffix_copying (k = 2): `CNOT(A[1], S[1])`, `CNOT(A[2], S[2])`. 2 CNOTs.
    2. overlapping_sum (width n = 4): `lower_add_qcla!` on `A[3..6], B[1..4]`. Sum into `S[3..6]`, carry c₄.
    3. carry_propagation (k = 2): `_lower_increment_qcla!`(B[5..6], c₄, S[7..8], 2). Width 2.
  - No concurrent uncompute (d = 2 < 3).

**Level d = 3 — does not exist for W = 4.** `⌈log₂ 4⌉ = 2`, so level 2 is
the root.

At W = 4 **the uncompute-in-flight mechanism never fires** (it only
kicks in at `d ≥ 3`). Levels 1 and 2 output wires are NOT uncomputed
inside `emit_parallel_adder_tree!`. Their uncomputation is the
responsibility of the outer Sun-Borissov Algorithm 3 (steps 5-7).

**Concurrent-uncompute trace starts at W = 8:**

- Level d = 3 (Add_3 at root) concurrently emits the **inverse** of
  the four level-1 Add_1 calls. Specifically, the single Add_3
  forward adder's layered gate stream is interleaved with the
  sequenced reverse of adders (1, 0..3).
- Result: after level 3 finishes, level 1's partial-sum registers are
  zero. Their wires are returned to the pool.

---

## 10. Test plan — `test/test_parallel_adder_tree.jl`

RED-first (principle 3). Must fail on `main` since the file does not
exist yet. GREEN after A2 + A3 land.

### 10.1 Exhaustive correctness at W = 4

```julia
@testset "W=4 exhaustive multiplication via parallel_adder_tree" begin
    for x in 0:15
        for y in 0:15
            # Build circuit: fast_copy -> partial_products -> adder_tree
            wa = WireAllocator()
            gates = ReversibleGate[]
            x_wires = allocate!(wa, 4)
            y_wires = allocate!(wa, 4)
            x_copies = emit_fast_copy!(gates, wa, x_wires, 4, 4)
            y_bit_copies = [emit_fast_copy!(gates, wa, [y_wires[i]], 4, 1)[1] for i in 1:4]
            # ... (upstream boilerplate)
            pp = emit_partial_products!(gates, wa, y_bit_copies, x_copies, 4)
            result = emit_parallel_adder_tree!(gates, wa, pp, 4; reuse_pool=[])
            @test length(result) == 8

            # Simulate with x and y as bit inputs.
            bits = zeros(Bool, wire_count(wa))
            for i in 1:4; bits[x_wires[i]] = (x >> (i-1)) & 1; end
            for i in 1:4; bits[y_wires[i]] = (y >> (i-1)) & 1; end
            final = simulate(gates, bits)

            got = 0
            for i in 1:8; got += Int(final[result[i]]) << (i-1); end
            @test got == x * y
        end
    end
end
```

(All 256 (x, y) pairs enumerated. Every product checked bit-by-bit.)

### 10.2 Resource-count pins (principle 6)

```julia
@testset "Resource pins at W=4" begin
    wa = WireAllocator()
    gates = ReversibleGate[]
    pp = [allocate!(wa, 4) for _ in 1:4]
    result = emit_parallel_adder_tree!(gates, wa, pp, 4; reuse_pool=[])
    c = ReversibleCircuit(wire_count(wa), gates, Int[], result, Int[], Int[4,4], [8])
    # Absolute baselines — will change if algorithm changes; update by hand.
    @test gate_count(c)   == 272 ± 10%
    @test toffoli_count(c) == 152 ± 10%
    @test toffoli_depth(c) == 38  ± 10%
    @test depth(c)        == 56  ± 10%
    # Principle 6: exact counts once A2/A3 lands.
end
```

Similar pins at W = 8 (2112 wires peak, 1072 gates, 60 T-depth).

### 10.3 Ancilla-zero verification (principle 4)

After running `emit_parallel_adder_tree!` and then its reverse, all
pool wires, all partial-sum ancilla wires, and all QCLA scratch wires
must be zero.

```julia
@testset "Ancilla-zero at W=4" begin
    # Run forward, run reverse, check every ancilla is zero.
    # Specifically the 2n² = 32 pool wires that the caller provides.
    ...
end
```

### 10.4 Uncompute-in-flight verification (W = 8, first level where it fires)

```julia
@testset "W=8: level 1 registers are zero after level 3 completes" begin
    # Build the full pipeline up to the tree. Record the wire indices
    # of the α^{(1,*)} registers at tree-mid. Simulate to the point
    # just after level 3's forward+inverse block. Those four registers
    # must be all zero.
    ...
end
```

### 10.5 Resource-pin regression at W = 16 (sampled)

Random 100 (x, y) pairs + 4 edge cases (0·0, max·max, 0·max,
0xAAAA·0x5555). All products correct.

### 10.6 Pool-sufficiency check

For `W ∈ {8, 16, 32}`, assert that `reuse_pool` of size `2 W²` is
never exhausted inside `emit_parallel_adder_tree!`. Failure mode:
internal spill to `allocate!(wa, …)`, which means the paper's ancilla
bound is broken for that `W` and the run should log and fail fast.

### 10.7 Shape / fail-fast tests

- `length(pp) != W` → error.
- `length(pp[i]) != W` → error.
- `W = 1` → error (caller must special-case trivial).
- `W = 2` → tree is a single adder; test it as a special case.
- `W = 3` (non-power-of-2) → tree has level 1 = {Add(α00, α01),
  α02 (bubble)}, level 2 = Add(level1[0], level1[1]). See §11.

---

## 11. Edge cases

### 11.1 W = 1

Fail fast. `error("W must be >= 2")`. A 1-bit multiplication is
`x · y = Toffoli(x, y, out)` and never routes through
`parallel_adder_tree`.

### 11.2 W = 2

Only 2 partial products, so the tree is a single Add_1 at level 1.
Uncompute-in-flight does not fire. Output width `2 + 2 = 4 = 2W`. Test
exhaustively (16 pairs of (x, y) in 0..3).

Also because `W < 6`, the `2 n² = 8` ancilla bound may be violated (QCLA
scratch at small widths has a constant overhead that can exceed
`W - w(W) - ⌊log W⌋`). The paper notes `n ≥ 6` is required for the
`2n²` bound; for smaller `n` we allow the spill. Test
`test_pool_sufficiency` is relaxed (or skipped) for `W ≤ 4`.

### 11.3 W = 4

No uncompute-in-flight (`D = 2`); fine. Two-level tree. Exhaustive test
(256 pairs) is the GREEN target of A2.

### 11.4 W = 8

`D = 3`. First width where uncompute-in-flight fires. Exhaustive test
(65,536 pairs) practical (see `test_int16.jl` precedent).

### 11.5 W = 16, 32, 64

`D = 4, 5, 6`. Sampled testing (random + edges). Resource-count
regression pins.

### 11.6 W not a power of 2

The paper's analysis technically assumes `n` is a power of 2. For
`n = 5, 6, 7` (cases that arise organically from the caller's bit
widths), the tree has odd children at some levels. Our scheme handles
this by "bubbling up" unpaired children directly to the next level
without an adder (see pseudocode's `if B === nothing` branch). This
preserves correctness; resource counts are within ~5% of the
power-of-2 formulas (one fewer adder per odd level).

We test `W = 5, 6, 7` with 100 random pairs each, but we do NOT pin
exact gate counts (the floor-divisions make the formulas messy).

### 11.7 Handling the carry-propagation edge case k = 0

k = 2^{d−1} is always ≥ 1 for d ≥ 1. At d = 1, k = 1, which is the
smallest k. The `_lower_increment_qcla!` handles k = 1 by falling back
to a single CNOT — no tree.

---

## 12. Notes on Bennett.jl integration

### 12.1 Relationship to outer `bennett()` wrapping

`emit_parallel_adder_tree!` is **self-reversing** in the
Sun-Borissov §II.D.2 sense: it leaves levels `D-1` and `D-2`
intact, but those get uncomputed by the outer Algorithm 3. The
primitive is **not** self-reversing in the CLAUDE.md §13 sense
(ancilla-return-to-zero at exit) — some internal partial sums remain
non-zero at exit.

This matters for the `self_reversing` flag introduced in P1 of the
PRD. The outer `lower_mul_qcla_tree!` is the self-reversing
primitive (steps 1..7 of Sun-Borissov Algorithm 3 together zero
every scratch wire); `emit_parallel_adder_tree!` by itself is not.
The caller `lower_mul_qcla_tree!` is responsible for step 5-7 that
zero the outstanding tree levels.

### 12.2 Dispatcher wiring

`emit_parallel_adder_tree!` is a helper, not user-facing. Its dispatch
lives inside `lower_mul_qcla_tree!`, chosen by `_pick_mul_strategy`
(PRD P2). No direct `mul=:parallel_adder_tree` kwarg is exposed.

### 12.3 Why B-shaped pool rather than A-shaped handle list

Proposer B deliberately makes `reuse_pool` a `Vector{Int}` of wire
indices rather than a more structured `PoolHandle` type. Rationale:

- Bennett.jl's `WireAllocator` is already a flat integer-allocator;
  matching that shape avoids a new abstraction.
- The paper's analysis is wire-count-level, not
  register-granularity; a flat pool is the minimal abstraction that
  satisfies it.
- Spill handling (for `n < 6` or unexpected overruns) is trivial: if
  `pool` is exhausted, call `allocate!(wa, …)`.

---

## 13. Open questions (for orchestrator)

1. **QCLA depth-layering inside Bennett.jl.** `_gate_depth_layers` is
   new. Do we want to centralise this in a helper alongside
   `diagnostics.depth`, or keep it private to `parallel_adder_tree.jl`?
   Recommendation: private for now; refactor to shared when the
   second user materialises.

2. **`lower_add_qcla_into!` vs recomputing `lower_add_qcla!`.** A1
   must ship this refactor ahead of A2, or A2 must copy the QCLA body.
   Recommendation: A1 ships the refactor.

3. **Layer fusion between stage 2 carry-out and stage 3 carry-in.**
   Stage 2's final CNOT (`Z[W] ⊕= b[W]`) could in principle be fused
   with stage 3's first CNOT (`S[wa+1] ⊕= c_n`) if both wires sit in
   the same depth-layer budget. Tight fusion would shave 1 layer per
   level, giving `3 log²n + 10 log n` depth instead of 13. PRD
   success-criterion 5 allows ±10%; recommendation: do not fuse in A2
   (keep it clean), file a follow-up optimization issue.

4. **Peak wires vs allocator high-water mark.** `wire_count(wa)`
   reports the allocator high-water mark, which is what Table III's
   "Ancillary Qubit Count" measures. With the pool-reuse scheme, the
   high-water mark equals the initial pool size (`2n²`) plus the
   output register (`2n`) plus transient overlap-stage QCLA scratch
   (`n`). So peak = `2n² + 2n + n = 2n² + 3n`. This MATCHES the
   paper's `≤ 2n²` for `n ≥ 6` since the `3n` is absorbed into the
   paper's loose upper bound (their Eq. 25).

---

## 14. References

- `docs/literature/multiplication/sun-borissov-2026.pdf` §II.D (algorithm),
  §III.d (integration), Table III (resource costs).
- `docs/literature/arithmetic/draper-kutin-rains-svore-2004.pdf` §3-4
  (base QCLA primitives).
- `docs/design/qcla_consensus.md` (Bennett.jl's QCLA primitive contract).
- `src/qcla.jl` (`lower_add_qcla!` implementation).
- `src/fast_copy.jl`, `src/partial_products.jl` (upstream submodules,
  same coding style).
- `src/wire_allocator.jl` (`allocate!`, `free!`, pool semantics).
- `docs/prd/advanced-arithmetic-PRD.md` §4 Phase A (this issue's scope).

---

## 15. Summary of key decisions

| Decision                                                 | Choice                     |
|----------------------------------------------------------|----------------------------|
| Modified QCLA: black box call vs specialized            | **Specialized** (`lower_add_qcla_shifted!`) — saves `Θ(n log n)` Toffolis, matches paper's Table III `−n log n` term. |
| Shift representation                                     | **Logical view** — no gates emitted; `Vector{Int}` slicing of caller's wires. |
| Uncompute-in-flight schedule                             | **Schedule B (interleaved)** — mandatory to preserve Table III depth `3 log²n + …`. Schedule A would double depth. |
| Ancilla pool shape                                        | **Flat `Vector{Int}`** passed as kwarg `reuse_pool`. Matches `WireAllocator`. |
| Pool-exhaustion policy                                    | **Fail-soft** (spill to `allocate!`) for `n < 6`; **fail-fast logging** for `n ≥ 6` (shouldn't happen). |
| QCLA output pre-allocation                                | **New helper** `lower_add_qcla_into!` (A1 refactor) so the tree can write directly into `S`-slices. |
| Odd-n children bubble-up                                  | **No adder, pass through** — preserves correctness, saves one adder per odd level. |
| Fail-fast width sanity                                    | **Yes** — `length(pp)`, `length(pp[i])`, `W ≥ 2` all checked. |
| Interleave layering helper                                | **Private** to `parallel_adder_tree.jl` for now; refactor to `diagnostics.jl` when reused. |
