# Proposer A — Parallel Adder Tree (Sun-Borissov 2026 §II.D)

Reference: Sun & Borissov 2026, *A Polylogarithmic-Depth Quantum Multiplier*,
arXiv:2604.09847. PDF at `docs/literature/multiplication/sun-borissov-2026.pdf`.
Target submodule: `src/parallel_adder_tree.jl`, entry point
`emit_parallel_adder_tree!`.

Design of **Step 4** of Algorithm 3 in the paper. Takes the `n` partial
products produced by `emit_partial_products!` and folds them into a single
`2n`-bit register holding `|xy>`. Uses a binary tree of modified Draper
QCLAs, with the level `d−2` adders uncomputed concurrently with level `d`
(paper §II.D.2).

Throughout this doc we use `n = W` interchangeably (the paper uses `n`, the
Bennett.jl code already lowered uses `W`). The input has `n = W` partial
products, each `W` bits wide.

---

## 1. Algorithm shape

### 1.1 Inputs / outputs

```
Input : α^(0,0), …, α^(0,W-1)          W registers, each W bits
Output: α^(D,0) = xy                   single register, 2W bits
```

where `D = ⌈log₂ W⌉`. At level `d`, we have `⌈W / 2^d⌉` partial sums
`α^(d,0), …, α^(d, ⌈W/2^d⌉-1)`, each of width `n + 2^d` bits (paper's
Claim 2). The full product `α^(D,0) = xy` has width `n + 2^D`. When `W`
is a power of two `2^D = W`, so the output is exactly `2W = 2n` bits.

### 1.2 Recurrence

Per paper Eq. (9):

```
α^(d,r) = α^(d-1, 2r) + 2^{2^{d-1}} · α^(d-1, 2r+1)
```

In words: at level `d`, pair up adjacent partial sums from level `d−1`,
left-shift the odd-indexed one by `2^{d-1}` bits, and add.

### 1.3 Register width convention (KEY DECISION)

The paper says α^(d,r) has `n + 2^d` bits, but with leading zeros from the
shift. We make these zeros **logical**, not **physical**: the output
register of `Add_d` is only physically allocated in the range where
non-trivial bits can arrive.

Specifically we partition the `n + 2^d`-bit output register into three
logical segments:

| Segment     | Bit range (0-based)                 | Width        | Physical?             |
|-------------|-------------------------------------|--------------|-----------------------|
| **low**     | `0 .. 2^{d-1} − 1`                  | `2^{d-1}`    | yes — suffix_copying  |
| **overlap** | `2^{d-1} .. 2^{d-1} + n − 1`        | `n`          | yes — overlapping_sum |
| **high**    | `2^{d-1} + n .. n + 2^d − 1`        | `2^{d-1}`    | yes — carry_propagation |

Total width: `2^{d-1} + n + 2^{d-1} = n + 2^d`. Good.

We allocate **one contiguous `n + 2^d`-bit register** per adder output.
The logical zero regions simply stay zero — we never touch those wires
except where the algorithm writes to them. This matches the paper's
"leading/trailing zeros" note and avoids the need to offset wire indices
at every call site.

For the leaf level (`d = 0`), α^(0,i) has width `n` (no shifts yet) and
is supplied by the caller as-is.

### 1.4 Tree layout

We build levels `d = 1, 2, …, D`. For each `d`, we produce
`⌈W / 2^d⌉` new partial sums. When `W` is not a power of two (edge case,
see §10), the last partial sum at some levels is an **orphan** passed
through unchanged (paper Eq. 12).

---

## 2. Modified QCLA split

At level `d`, each `Add_d` computes `α^(d,r) = α^(d-1, 2r) + 2^{2^{d-1}} ·
α^(d-1, 2r+1)`. Let `k = 2^{d-1}` (shift amount) and `m = n + 2^{d-1} =
n + k` (width of the first operand, α^(d-1, 2r)). The second operand after
shift has `n + 2k` bits, but the low `k` bits are zero and the top `k`
bits are the shifted-up portion of α^(d-1, 2r+1).

Let:
- `A = α^(d-1, 2r)` of width `m = n + k`
- `B = α^(d-1, 2r+1)` of width `m = n + k` (at `d ≥ 2`; at `d = 1`, `m = n`)
- `Z = α^(d,r)` of width `n + 2k`

The sum `A + 2^k · B` writes into `Z` as:

```
Z[0..k-1]         = B[0..k-1]                                 (suffix_copying)
Z[k..k+m-1]       = A[0..m-1]  +  B[0..m-1]                   (overlapping_sum)   ← m-bit QCLA
Z[k+m..n+2k-1]    = carry_out of overlapping_sum (propagated) (carry_propagation)
```

Wait — let me redo this carefully. The shifted operand `2^k · B` has
zeros at bits `0..k-1` and the value `B` at bits `k..k+m-1`. So where
does overlap happen?

- Bits `0..k-1`: only `A` contributes (if it has those bits) — but `A`'s
  low bits are `A[0..k-1]`. And `B`'s shifted form is zero there. So
  `Z[0..k-1] = A[0..k-1]` — NOT `B[0..k-1]`.

Let me re-read the paper... In paper §II.D.1 item 1:

> **suffix_copying**: The least significant `2^{d−1}` qubits of
> `α^(d−1,2r+1)` are copied directly to the least significant `2^{d−1}`
> qubits of the output register.

So the paper copies the LOW bits of `α^(d-1,2r+1)` (i.e. the shifted
operand's LSBs that land in the unshifted-operand's low region). Re-read:
**which operand has zero in the low `k` bits?** The shifted operand
`2^k · B` is zero in bits `0..k-1`, while `A` lives in bits `0..m-1`.
So the low `k` bits of the sum should get `A[0..k-1]`, not `B[0..k-1]`.

But the paper says `α^(d-1,2r+1)` — that's `B` in my notation. Which
means the paper is treating the SHIFTED register, not `B` itself — it's
saying "the low `k` bits of the output go to the shifted operand's
contribution, but the shifted operand is zero there, so actually copy
the OTHER operand's low bits". Let me look again at Fig. 2.

Fig. 2 labels: input 0 is `α^(d-1, 2r)` (non-shifted), input 1 is
`α^(d-1, 2r+1)` (shifted), output 2 is `α^(d,r)`. The `0 .. 2^{d-1}-1`
positions of output 2 come from the non-shifted operand's low `2^{d-1}`
positions (input 0's low `k` bits). The paper text is a bit confusing
but the figure is unambiguous.

**Correction — I had the roles flipped.** Let me restate with the right
labels:

- **suffix_copying** (low region `0..k-1`): copy `A[0..k-1]` into
  `Z[0..k-1]` via `k` CNOTs. The shifted operand contributes zero here.
- **overlapping_sum** (mid region `k..k+n-1`): add `A[k..k+n-1]` to
  `B[0..n-1]` via an `n`-bit out-of-place QCLA producing an `(n+1)`-bit
  result. Low `n` bits go to `Z[k..k+n-1]`; the high carry bit goes
  into `Z[k+n]`.
- **carry_propagation** (high region `k+n..n+2k-1`, width `k`): the
  carry coming out of `Z[k+n]` must propagate through `A[k+n..m-1]`
  (the high `k` bits of `A`). The paper says "second input is all-zero
  ancilla" — but instead of allocating `k` zero wires, we **re-use the
  QCLA structure** where the second operand is logically zero. The
  paper's trick is: since the second operand is zero, we simplify the
  QCLA to a carry-propagate network through `A`'s high bits and then
  CNOT the high bits of `A` onto the corresponding Z bits.

Let me re-check by writing out the arithmetic. At level `d = 1`, `k =
1`, `n = W`. Each adder sums two `W`-bit partial products
`α^(0, 2r) + 2·α^(0, 2r+1)`:

```
bit  0:       A[0]                                = Z[0]    (suffix)
bit  1..W:    A[1..W-1] + B[0..W-1] + carries     = Z[1..W] (overlap: W bits)
bit  W+1:     carry_out_of_overlap                = Z[W+1]  (high: 1 bit)
```

Here `m = n + k = W + 1` is `A`'s width at `d=1` (after lifting? no — at
`d=1`, A is `α^(0,2r)` which has width `n = W`, not `W + 1`). So the
formulas differ at level 1 vs level ≥ 2:

**At level d = 1** (`k = 1`):
- A and B both have width `n` (leaves).
- suffix_copying: 1 CNOT (`Z[0] = A[0]`)
- overlapping_sum: `(n-1)`-bit add of `A[1..n-1]` and `B[0..n-2]`; but
  `B[n-1]` sits at output bit `n` which has no `A` partner... wait.

Let me just write out the paper's exact statement:

> overlapping_sum: Following Draper, we perform the standard QCLA on the
> overlapping region consisting of `n + 2^d − 2·2^{d-1} = n` qubits,
> saving the carry-out bit from this addition in a 1-qubit register
> `c^(d,r)`.

So at every level, overlapping_sum is exactly `n` bits wide. Width of
both operands in the overlap region = `n`. The carry-out is 1 bit.

Then carry_propagation "is added with the most significant `2^{d-1}`
qubits of `α^(d-1, 2r+1)` using a modified QCLA where all qubits other
than the carry are logically fixed to |0>".

So it IS the high part of `α^(d-1, 2r+1)` = `B`, not the high part of `A`.
That means the picture is:

**Level d ≥ 2** — `k = 2^{d-1}`, both operands have width `n + k`:

```
                ┌─────── A (width n+k) ───────┐
                │ A[0..k-1] │ A[k..k+n-1]     │
                └───────────┴─────────────────┘

                           ┌─────── B shifted by k (width n+2k) ───────┐
                           │ B[0..n-1]     │ B[n..n+k-1]               │
                 (0..k-1) 0│ at bits k..k+n│ at bits k+n..n+2k-1       │
                           └───────────────┴───────────────────────────┘

Output Z width n+2k:
 bits 0..k-1     = A[0..k-1]                               (suffix_copying on A's low)
 bits k..k+n-1   = A[k..k+n-1] + B[0..n-1]                 (overlapping_sum, n-bit)
 bit  k+n        = carry_out of overlap                    (explicit 1-qubit)
 bits k+n+1 ..
      n+2k-1     = propagated carry through B[n..n+k-1]    (carry_propagation, k−1 wide)
```

Wait, but the total is `k + n + 1 + (k-1) = n + 2k`. And `B[n..n+k-1]`
lives at bits `k+n..n+2k-1` after the shift of `k`. So carry_propagation
takes the carry bit (at `Z[k+n]`) plus `B[n..n+k-1]` (at bits `Z[k+n]`
through `Z[n+2k-1]`) — but hang on, B[n] is at shifted bit `n+k`, same
bit as the carry-out. So these collide.

Re-read paper carefully (§II.D.1 paragraph 4):

> The carry-out qubit is added with the most significant `2^{d-1}` qubits
> of `α^(d-1,2r+1)` using a modified QCLA where all qubits other than
> the carry are logically fixed to |0>.

And then:

> Indeed, the first step of the modified QCLA is to perform a CNOT gate
> from each of the most significant `2^{d-1}` qubits of `α^(d-1,2r+1)`
> onto `|0>^{⊗2·2^{d-1}−1}|c^(d,r)>`. So the leading zeros of the second
> register are now logically equivalent to the corresponding bits of the
> first register.

OK — so in carry_propagation the inputs are:
- First operand: the `k` most-significant bits of `B` = `B[n..n+k-1]`
- Second operand: `k-1` zero wires + the carry-bit `c^(d,r)`

But the `k-1` zeros + carry-bit form the second `k`-bit operand to a
**`k`-bit QCLA**. And the "zero operand" trick collapses: a CNOT from
`B[n+i]` onto the "zero" wire produces `B[n+i]`, so effectively we run
a QCLA of (`B`'s high bits) + (carry in LSB, zeros elsewhere). The low
bit of the output is `B[n] ⊕ carry`, and higher bits are `B[n+1..n+k-1]`
plus propagate.

**This is the point where my design diverges from a naive black-boxing
of `lower_add_qcla!`.** The second operand is mostly-zero with one "1"
bit at the LSB (the carry). We could allocate `k` zero wires, CNOT the
carry onto the low one, call `lower_add_qcla!`, then uncompute the CNOT.
But the paper shows we can be smarter.

### 2.1 Three strategies for carry_propagation

**Strategy α (simple, wasteful):** Allocate `k` fresh zero wires, CNOT
the carry onto position 0 of that register, call `lower_add_qcla!(A=B[n..n+k-1], B=zeros, W=k)`.
Extract the result. Uncompute the CNOT to restore the carry. Free the
zero wires. Cost: `5k − 3w(k) − 3⌊log₂ k⌋ − 1` Toffolis (QCLA cost at
width `k`) plus overhead. **Adequate but loses the paper's savings.**

**Strategy β (paper §II.D.1 literal, preferred):** Use the "fan-out"
trick: run a modified QCLA where the second-operand "zero wires" are
implicit. A CNOT from each high bit of `B` onto each corresponding wire
of the output register, followed by a QCLA-carry-chain whose base-G
initialization uses the carry as the only non-trivial generate. This
saves the `k` zero-wire allocation.

**Strategy γ (hybrid, this proposal):** Since `k − 1` of the `k` output
bits equal `B[n+i] ⊕ (carry propagated)`, and the carry propagates only
if `all B[n..n+i-1]` are 1 (that's an AND-chain), we could emit this as
a small ripple-carry with `k−1` Toffolis and `2k − 2` CNOTs. This has
depth `O(k)` not `O(log k)`, which is bad at large `k`. REJECTED for
large `d` but useful as a fallback at small `k`.

**DECISION: Strategy β.** Implement a helper
`_carry_propagate_through_zeros!(gates, wa, carry_bit, b_high, z_high, k)`
that emits the modified QCLA. This keeps the paper's depth claim.

### 2.2 Implementation of carry_propagation (modified QCLA variant)

At this subroutine, the second operand `q = [carry_bit, 0, 0, …, 0]`
(`k` bits, LSB is the carry). The QCLA's Phase 1 (init G: `Z[j+1] ⊕=
b_high[j] · q[j]`) becomes a single Toffoli at j=0 — but since `q[j]=0`
for `j ≥ 1`, those Toffolis are NOPs and are omitted. Phase 2 (init P:
`q[j] ⊕= b_high[j]`) — since `q[j]=0` for `j ≥ 1`, we just CNOT
`b_high[j]` onto `q[j]` for `j ≥ 1`. This is the "fan-out" step the
paper describes.

AFTER the fan-out, `q` holds `[carry_bit, b_high[1], b_high[2], …,
b_high[k-1]]`. Now `q` is byte-for-byte equal to what `b`'s propagate
would look like in a full `k`-bit QCLA with `a = b_high, b = q`. So we
can literally call `lower_add_qcla!(a=b_high, b=q, W=k)` from this
point onwards — the remainder of the QCLA is unchanged.

BUT this still allocates `k` wires for `q`. The paper's insight
(§II.D.1 last sentence before §II.D.2) is that `q` **IS** the output
register `z_high`. That is, we use the allocated `z_high` wires as
`q`, pre-initializing them via the fan-out CNOTs. No fresh zero
register needed — just use `z_high` itself.

So the flow is:

```
# z_high wires are pre-allocated zero (part of the output register)
# carry_bit lives at z[k+n] (the overflow bit from overlapping_sum)
# b_high = B[n..n+k-1]

# Step 1 — CNOT fan-out from b_high onto z_high[1..k-1]
#          (z_high[0] gets the carry from overlapping_sum — already there)
for j in 1:k-1
    push!(gates, CNOTGate(b_high[j+1], z_high[j+1]))
end

# Now z_high = [carry, b_high[1], b_high[2], ...]
# Next: run QCLA carry-tree on (b_high, z_high) writing carry values into
#       output register Z_out of width k+1. But Z_out's low k bits are
#       exactly z_high (overwriting); the top bit is the final overflow.

# Since the final-level carry at d=D-1 would exceed our n+2k budget and
# the paper says only the final level keeps the carry (§II.D.1 end:
# "leading zeros of second register"), we drop it.
#
# At internal levels the top bit slot is the MSB of the n+2k output,
# which is already allocated and should catch the final overflow.
```

**There is a subtle point here.** The fan-out turns `z_high` from
`[carry, 0, …, 0]` into `[carry, b_high[1], …, b_high[k-1]]`. This IS
NOT the bitwise sum we want: the bitwise sum of `(0, b_high[1..k-1])`
and `(carry, 0, …, 0)` is exactly that vector, which is correct because
no two input bits collide at any position. So the fan-out IS the sum
at bit level for the high region — but we still need to propagate
carries from the low bit upward.

Example (`k=3`, `carry=1`, `b_high=[1, 0, 1]`):
- After fan-out: `z_high = [1, 0, 1]` — but the true sum is
  `(1,0,1) + (1,0,0) = (0,1,1)` with carry_out=0. Simple bit-union
  is wrong when `b_high[0]` AND `carry` both equal 1.

So we **still need a real adder** for the overlap between `carry_bit`
and `b_high[0]`. The QCLA handles this: after fan-out, Phase 3
(carry tree) and Phase 4 (form-sum CNOTs) of the QCLA do the carry
propagation correctly.

**Final design of carry_propagation:**

```julia
function _emit_carry_propagation!(gates, wa, carry_bit, b_high, z_high, k)
    # carry_bit: single wire; already AT z_high[1] (aliased).
    # b_high: k-wire register holding B[n..n+k-1].
    # z_high: k-wire contiguous slice of output register.
    #         z_high[1] == carry_bit (already placed by overlapping_sum).
    #         z_high[2..k] start as zero.

    # We run a k-bit QCLA with:
    #   operand a = b_high (length k)
    #   operand b = z_high (length k), initially [carry, 0, 0, …, 0]
    # producing output of width k+1. The top bit will be the tree's overall
    # overflow, which lives at the wire just ABOVE z_high (bit k+1 of z).
    # If the output register is exactly k wires wide (no overflow slot), we
    # drop the carry-out — but the paper's width budget n+2k INCLUDES it.

    # Delegate to lower_add_qcla! entirely (black-box), then CNOT result
    # back onto z_high to overwrite in place. Overhead = k + ancilla
    # wires, acceptable.
    k == 0 && return                             # nothing to do at d=0 (empty)

    result = lower_add_qcla!(gates, wa, b_high, z_high, k)  # length k+1
    # result[1..k] = (b_high + z_high) mod 2^k  = the high bits of the
    # true sum; result[k+1] = overflow, which goes into the top wire of
    # Z_out.

    # Copy result back into z_high and top wire.
    for j in 1:k
        push!(gates, CNOTGate(result[j], z_high[j]))
    end
    push!(gates, CNOTGate(result[k+1], z_top_wire))

    # Uncompute b_high+z_high QCLA in reverse — but wait, this destroys
    # z_high. We need z_high to HOLD the result, not just copy it out.
end
```

**Hmm.** This doesn't compose cleanly because `lower_add_qcla!` is
out-of-place: it produces a FRESH result register of width `k+1` while
leaving its inputs alone. That's wasteful here because we want the
output IN the already-allocated `z_high`+overflow-bit wires.

**Revised approach for carry_propagation (final):**

Emit a tailored in-line variant. Since the second operand starts as
`[carry_bit, 0, 0, …, 0]` (not arbitrary `b`), we can skip Phase 1's
Toffoli at `j = 0` (it's just `carry_bit · B[n+0]` → result wire, but
that wire is the carry-out of the level's overflow, already allocated).

Actually, the cleanest formulation is to emit a dedicated
`_lower_add_qcla_inplace_sparse_b!` that mutates `b` in place and takes
advantage of `b` being sparse (single `1` at LSB).

**FINAL DECISION:** Accept the overhead of Strategy α (fresh `k`-zero
register, standard `lower_add_qcla!`, then CNOT-copy + uncompute). This
is cleanest to implement, uses the existing QCLA black-box, and is
only `O(k)` extra gates per adder. Since there are `n / 2^d` adders at
level `d` and `k = 2^{d-1}`, the extra gates per level are
`O((n / 2^d) · 2^{d-1}) = O(n/2)` = constant per level, `O(n log n)`
total — within the paper's stated bound (they have `O(n log n)` slack
in their Toffoli count).

Implementation sketch (cleanly):

```julia
function _emit_carry_propagation!(gates, wa, overlap_carry, b_high, z_high, z_top, k)
    # overlap_carry: single wire = carry-out of overlapping_sum
    # b_high:   k-wire register (B's high k bits)
    # z_high:   k-wire contiguous slice of output register (all zero)
    # z_top:    single wire (top bit of output register)
    # k:        width

    k == 0 && return   # d=0, no high bits

    if k == 1
        # Degenerate: single bit. Z_high[1] = overlap_carry ⊕ b_high[1].
        # Z_top = overlap_carry ∧ b_high[1].
        push!(gates, CNOTGate(b_high[1], z_high[1]))
        push!(gates, CNOTGate(overlap_carry, z_high[1]))
        push!(gates, ToffoliGate(overlap_carry, b_high[1], z_top))
        return
    end

    # General k ≥ 2: run a k-bit out-of-place QCLA on (b_high, q)
    # where q is a freshly allocated k-wire zero register with q[1] set
    # to carry. Then CNOT-copy result into z_high/z_top, and uncompute
    # q via inverse QCLA. Net: z_high and z_top hold the sum; q is zero
    # again and is freed.
    q = allocate!(wa, k)
    push!(gates, CNOTGate(overlap_carry, q[1]))   # q = [carry,0,...,0]

    r = lower_add_qcla!(gates, wa, b_high, q, k)  # r has length k+1

    for j in 1:k
        push!(gates, CNOTGate(r[j], z_high[j]))
    end
    push!(gates, CNOTGate(r[k+1], z_top))

    # Uncompute: `lower_add_qcla!` is self-cleaning for its ancillae but
    # not for its output. Invert by running the gate list in reverse —
    # this is handled by Bennett's outer construction when wrapping this
    # submodule. Here at the *block* level we simply leave r populated;
    # the outer `parallel_adder_tree` uncompute pass takes care of it.

    # For NOW (self-contained adder-tree module), we inline the inverse:
    push!(gates, CNOTGate(overlap_carry, q[1]))   # undo the CNOT onto q[1]
    _inverse_qcla!(gates, r, b_high, q, k)        # uncompute QCLA, restoring
                                                   # q to zero and r to zero
    free!(wa, q)
    free!(wa, r)   # r also zeroed by the inverse QCLA
end
```

The `_inverse_qcla!` helper is a line-for-line reverse of
`lower_add_qcla!`'s gate list — Bennett.jl already has this pattern
(see `bennett.jl` inverse wrap). We factor it as a helper on
`src/qcla.jl` for reuse.

**Net cost of carry_propagation at width `k`:**
- 2 CNOTs to wire the carry into `q` and undo
- `5k − 3w(k) − 3⌊log₂ k⌋ − 1` Toffolis (forward QCLA)
- `3k − 1` CNOTs (forward QCLA)
- `(k + 1)` CNOTs to copy result into `z`
- Same Toffoli+CNOT count again for the inverse QCLA

Asymptotically `O(k)` Toffolis, `O(k)` CNOTs, ancilla `k + (k − w(k) −
⌊log₂ k⌋) + 1 ≈ 2k`. Summed across all adders at level `d`: `(n / 2^d) ·
2^{d-1} = n/2` Toffolis per level, `O(n log n)` total — below the paper's
`10n² − n log n` headroom.

### 2.3 overlapping_sum (uses `lower_add_qcla!` as a black box)

Straightforward: it's a standard `n`-bit QCLA on
`(A[k..k+n-1], B[0..n-1])` producing an `(n+1)`-bit result. The low `n`
bits go to `Z[k..k+n-1]`; the top bit is the overflow that feeds
carry_propagation.

Call sequence at each adder:

```julia
result = lower_add_qcla!(gates, wa, a_mid, b_mid, n)  # result length n+1
# CNOT result → z_mid, saving top bit as the carry for next stage
for j in 1:n
    push!(gates, CNOTGate(result[j], z_mid[j]))
end
carry_out = result[n+1]   # alias — this IS the wire we pass as overlap_carry
```

### 2.4 suffix_copying

`k` CNOTs from `A[0..k-1]` to `Z[0..k-1]`. (At `d = 1`, `k = 1`, this is
a single CNOT.) Toffoli-depth 0. Total cost across the tree:
`Σ_d (n / 2^d) · 2^{d-1} = Σ_d n/2 = (D · n)/2 = O(n log n)` CNOTs.

---

## 3. Uncompute-in-flight

### 3.1 Schedule options (recap from prompt)

(a) Linearize: emit level-d compute, then level-(d−2) uncompute as
separate blocks. Simple; misses depth savings but doesn't lose Toffoli
count.

(b) Interleave at instruction level: emit adder-d and inverse-adder-(d−2)
Toffolis in a single pass on disjoint wires. Needs wire-disjointness
proof; gives the paper's depth.

(c) Emit as sequential blocks with metadata so a downstream scheduler
could overlap.

### 3.2 DECISION: Option (a) — linearize, with TODO for (c)

Rationale:

1. **Correctness first (principle 1).** Option (b) requires proving
   wire-disjointness between `Add_d` at level `d` and `inverse-Add_{d-2}`
   at level `d-2`. This is true in principle (level `d-2` produces
   wires consumed at level `d-1`, and level `d-1` consumes them into
   level `d`; by the time level `d` starts, level `d-2` outputs are
   no longer needed and their input registers — the level-`d-3`
   outputs — can be uncomputed). But proving this with bennett.jl's
   current wire tracking requires additional static analysis. Doing
   it right is a 3+1 agents task on its own.

2. **Bennett.jl has no scheduler.** Gates are emitted in strict
   sequential order and the simulator executes them in that order. A
   scheduler-aware pass could re-order commuting gates (analogous to
   T-depth fusion in QCLA — which we also explicitly deferred), but
   it's work outside this primitive.

3. **Option (a) preserves the Toffoli-count bound exactly.** The paper's
   Toffoli count (`10n² − n log n`) is the same whether we linearize or
   interleave; only the Toffoli-DEPTH differs. Our current metrics
   (`toffoli_depth`) will report the linearized depth, which is `~2×`
   the paper's stated depth. This is a known, documented, recoverable
   regression — fix in a follow-up pass once the scheduler lands.

4. **Matches the QCLA consensus doc's "timeslice fusion" deferral.**
   Same class of optimization; same justification.

### 3.3 Linearized schedule

```
# Forward pass (level 1 upward)
for d in 1:D
    for r in 0:⌈W/2^d⌉-1
        emit Add_d[r]   # consumes α^(d-1, 2r) and α^(d-1, 2r+1)
    end
end

# Uncompute pass (levels D-2 downward to 1, parallel-in-principle but
# linearized)
for d_uncompute in (D-2):-1:1
    for r in 0:⌈W/2^{d_uncompute}⌉-1
        emit inverse-Add_{d_uncompute}[r]
        # This restores α^(d_uncompute-1, 2r) and α^(d_uncompute-1, 2r+1)'s
        # *output register* for α^(d_uncompute, r) to zero.
    end
end

# Only the root α^(D, 0) = xy survives.
```

Wait — this isn't quite right. The paper §II.D.2 says:

> Beginning at `d = 3`, the adders at level `d − 2` are uncomputed
> concurrently with the computation of the partial sums at level `d`.

So the uncompute is INTERLEAVED with the forward pass, not done after.
Specifically:
- While computing level `d`, simultaneously uncompute level `d − 2`.
- Level `d − 2`'s OUTPUTS (α^(d-2, r)) are the INPUTS to level `d − 1`
  which is now complete — so level `d − 2`'s partial sums are garbage
  that can be zeroed.
- Uncomputing `Add_{d-2}[r]` zeroes `α^(d-2, r)`, freeing those wires.

Linearized version:

```
compute level 1
compute level 2
for d in 3:D
    compute level d   AND   uncompute level d-2
```

Where each "AND" is sequential: emit level d first, then inverse level
d-2. OR emit the inverse first, then level d — depends on whether level
d-2 wires are still needed. Since level d-2's outputs were already
consumed by level d-1 (which is at this point complete), they are
unused — safe to uncompute first.

**Precise linearized schedule:**

```
emit_level(1)
emit_level(2)
for d in 3:D
    emit_inverse_level(d - 2)
    emit_level(d)
end
```

Final state after this loop: level `D`'s output (α^(D,0) = xy) is live;
levels `D − 1` and `D − 2` are still live (we only uncomputed up to
`D − 2`). Final cleanup:

```
# After the loop, levels D-1 and D-2 are still live. Uncompute them.
emit_inverse_level(D - 1)
emit_inverse_level(D - 2)   # already done if D ≥ 4; skip if D ≤ 2
```

Wait — the paper says "except for the final level, which is not
uncomputed". So we uncompute EVERYTHING below the root. The root is
α^(D, 0) — the product. Everything else goes back to zero.

After the main loop, we still have level `D − 1` (two partial sums) and
level `D − 2` (four partial sums) live. These are both consumed by the
final `Add_D` and `Add_{D-1}` respectively. So:
- Level `D − 1` is consumed by `Add_D`; after `Add_D`, level `D − 1` is
  no longer needed. Uncompute it.
- Level `D − 2` is consumed by level `D − 1`; similarly uncomputed
  inside the main loop (at iteration d = D).

Wait, at iteration `d = D`, we uncompute level `D − 2`. So after the
loop, only level `D − 1` remains live. One final pass:

```
emit_inverse_level(D - 1)
```

And optionally level 0 (the leaf partial products), but those are the
caller's responsibility — they're the `α^(0,i)` inputs. The outer
Algorithm 3 calls `uncompute_partial_products` in a separate step (step
6).

### 3.4 Net ancilla flow

| Step                              | Live partial-sum levels     | Live wires         |
|-----------------------------------|-----------------------------|--------------------|
| start                             | 0                           | n · n = n²         |
| after compute level 1             | 0, 1                        | n² + (n/2)(n+2)    |
| after compute level 2             | 0, 1, 2                     | n² + (n/2)(n+2) + (n/4)(n+4) |
| after compute level d, d ≥ 3      | 0, 1, d-2, d-1, d           | (complicated)      |
| inverse level d-2 frees           | 0, 1, d-1, d                | ↓ by `(n / 2^{d-2}) · (n + 2^{d-2})` |

The paper §II.D.3 does the careful accounting and concludes total ≤
`2n²` for `n ≥ 6`.

---

## 4. Ancilla accounting

### 4.1 Per-level fresh allocation

At level `d`, the number of fresh output wires allocated is:
```
n_d_output = ⌈n / 2^d⌉ · (n + 2^d)    (paper Eq. 13)
```

At level `d`, each adder additionally uses the QCLA's computational
ancillae during overlapping_sum and carry_propagation. From
`lower_add_qcla!`:
- overlapping_sum is `n`-bit, using `n − w(n) − ⌊log₂ n⌋` ancillae
- carry_propagation is `k`-bit, using `k − w(k) − ⌊log₂ k⌋` ancillae
  (plus `k` for the fresh `q` zero register)

But these ancillae are **allocated, used, and freed** inside each call
to `lower_add_qcla!` — they're transient and don't accumulate. Paper
calls this the "`n/2^d`-ancilla reuse" (§II.D.3.a): all adders at level
`d` run sequentially in our linearized emission, so only ONE adder's
ancillae are live at any instant.

### 4.2 Recycling the `freed_ancilla` pool from outer step 3

The outer algorithm (Sun-Borissov Alg. 3) calls `uncompute fast_copy`
before `parallel_adder_tree` (step 3). This frees the `2n²` ancillae
that held the `fast_copy` replicas of `|x>` and `|y>`. The paper uses
these for all the partial-sum storage at later levels.

In Bennett.jl's wire allocator, `free!(wa, wires)` returns wires to the
allocator's free list. Subsequent `allocate!(wa, n)` will reuse them
first. So IF the caller passes the freed wires back via `freed_ancilla`
kwarg, we can `free!(wa, freed_ancilla)` at the start of the tree and
let the allocator hand them out for partial-sum registers.

### 4.3 Ancilla check

Paper Eq. 17: total ancilla at level `d` is at most `n² + dn`. Maximum
across all `d ∈ [1, log n]` is `n² + n log n` if we didn't uncompute;
with uncompute-in-flight, max is `n² + 3n` at `d = 3` (paper Eq. 24),
bounded by `(3/2) n² + 3n ≤ 2n²` for `n ≥ 6` (paper Eq. 25).

**Our implementation target: `peak_live_wires(circuit) ≤ 2n²` for
`n ≥ 8`.** Tested directly.

---

## 5. API surface

```julia
"""
    emit_parallel_adder_tree!(gates, wa, partial_products, W; freed_ancilla=Int[])
        -> Vector{Int}

Sum the W partial products α^(0, 0) … α^(0, W-1) into a single 2W-bit
register holding xy, using Sun-Borissov 2026 §II.D's binary tree of
modified Draper QCLAs.

`partial_products` is a length-W vector; each entry is a W-wire register
storing the i-th partial product α^(0, i). These wires are UNCHANGED on
exit (the caller uncomputes them separately, per Algorithm 3 step 6).

`freed_ancilla` is an optional vector of wires that the caller has freed
prior to this call (e.g. the 2n² wires from Algorithm 3 step 3's
uncompute-fast_copy). If supplied, these wires are returned to the
allocator's free list before any level-1 allocations, enabling the paper's
in-place reuse claim.

Returns the 2W-wire result register holding |xy>.

On exit:
- All intermediate partial-sum registers are uncomputed (zero).
- `freed_ancilla` wires are back in the free list (may have been reused
  during the tree; the allocator state is consistent).
- Only the returned 2W wires hold live data (|xy>).

Gate counts (target, ±10% per PRD §5.5):
  Toffoli : 10W² − W log W  (Eq. 32 + Eq. 26 = dominated by overlapping_sum)
  Toffoli-depth : 3 log² W + 7 log W + 12  (Eq. 29; linearized version may
                be up to 2× this until a scheduler pass lands)
  Total gates : 16W² + 2W log W  (Eq. 27 + Eq. 28)
  Ancilla  : ≤ 2W² for W ≥ 6  (Eq. 25)
"""
function emit_parallel_adder_tree!(gates::Vector{ReversibleGate},
                                   wa::WireAllocator,
                                   partial_products::Vector{Vector{Int}},
                                   W::Int;
                                   freed_ancilla::Vector{Int}=Int[])
```

### 5.1 API decisions

1. **Self-contained uncompute.** The function handles its own uncompute-
   in-flight. Callers don't need to wrap in `bennett()`. This matches the
   `self_reversing` flag PRD's intent for the Sun-Borissov primitives.

2. **`freed_ancilla` is a kwarg, not positional.** Defaults to `Int[]`.
   When the outer Algorithm 3 is assembled, `lower_mul_qcla_tree!` will
   pass it. Unit tests can omit it.

3. **Return type is `Vector{Int}` of length `2W`.** Bit 1 is LSB. This
   matches `lower_mul_wide!` and `lower_add_qcla!`'s conventions.

4. **Fail-fast preconditions** (principle 1):
   - `W ≥ 2` (for `W = 1`, no adder tree needed — single partial product
     IS the product, zero-padded; handled via guard, not an error)
   - `length(partial_products) == W`
   - `all(length(pp) == W for pp in partial_products)`
   - `W` must be a positive integer

5. **No mutation of inputs.** `partial_products` are reads-only. This
   aligns with Algorithm 3 step 6 which uncomputes them separately.

---

## 6. Julia-style pseudocode

```julia
"""
    emit_parallel_adder_tree!(gates, wa, partial_products, W; freed_ancilla=Int[])

Sun-Borissov 2026 §II.D. Tree of modified QCLAs summing W partial products.
"""
function emit_parallel_adder_tree!(gates::Vector{ReversibleGate},
                                   wa::WireAllocator,
                                   partial_products::Vector{Vector{Int}},
                                   W::Int;
                                   freed_ancilla::Vector{Int}=Int[])
    W >= 1 || error("emit_parallel_adder_tree!: W must be >= 1, got $W")
    length(partial_products) == W ||
        error("emit_parallel_adder_tree!: expected $W partial products, got $(length(partial_products))")
    for (i, pp) in enumerate(partial_products)
        length(pp) == W ||
            error("emit_parallel_adder_tree!: partial_products[$i] has $(length(pp)) wires, expected $W")
    end

    # Recycle freed ancillae from outer step 3
    isempty(freed_ancilla) || free!(wa, freed_ancilla)

    D = W == 1 ? 0 : ceil(Int, log2(W))

    # W = 1 degenerate: product is just α^(0,0), zero-padded to 2W = 2 bits.
    if W == 1
        result = allocate!(wa, 2)
        push!(gates, CNOTGate(partial_products[1][1], result[1]))
        # result[2] stays zero (2W = 2, but α^(0,0) is only 1 bit)
        return result
    end

    # Storage for each level's partial sums. Level 0 is the input.
    # `levels[d+1]` (1-based) is a vector of partial-sum registers at level d.
    levels = Vector{Vector{Vector{Int}}}(undef, D + 1)
    levels[1] = partial_products   # level 0

    # ---- Forward pass, linearized with uncompute-in-flight ----
    # emit_level(1), emit_level(2)
    levels[2] = _emit_one_level!(gates, wa, levels[1], 1, W)      # level d=1
    D >= 2 && (levels[3] = _emit_one_level!(gates, wa, levels[2], 2, W))  # level d=2

    # Main loop: at iteration d, emit inverse of level d-2, then emit level d.
    for d in 3:D
        _emit_inverse_level!(gates, wa, levels[d - 1], levels[d - 2 + 1], d - 2, W)
        free!(wa, _flatten(levels[d - 2 + 1]))   # reclaim wires
        levels[d + 1] = _emit_one_level!(gates, wa, levels[d], d, W)
    end

    # Final cleanup: uncompute level D-1 (its outputs are now consumed)
    if D >= 2
        _emit_inverse_level!(gates, wa, levels[D], levels[D - 1 + 1], D - 1, W)
        free!(wa, _flatten(levels[D - 1 + 1]))
    end

    # Only level D's α^(D, 0) remains: that's xy.
    result = levels[D + 1][1]   # length 2W if W is power of 2; else zero-padded
    length(result) == 2*W || _pad_to_2W!(result, 2*W)
    return result
end


"""
    _emit_one_level!(gates, wa, prev_level, d, W) -> Vector{Vector{Int}}

Emit all Add_d adders for level d. Takes the level-(d-1) partial sums as
input. Returns the level-d partial sums. Ancilla-transparent: any QCLA
ancillae are allocated and freed inside each adder call.
"""
function _emit_one_level!(gates, wa, prev_level, d, W)
    k = 1 << (d - 1)      # shift amount 2^{d-1}
    out_width = W + (1 << d)   # n + 2^d
    prev_width = W + (1 << (d - 1))   # n + 2^{d-1}; at d=1 this is n, OK
    if d == 1
        prev_width = W
    end

    new_level = Vector{Vector{Int}}()
    n_prev = length(prev_level)
    n_new = cld(n_prev, 2)   # ⌈prev / 2⌉ — handles odd prev

    for r in 0:(n_new - 1)
        i_even = 2r + 1    # 1-based index of prev_level[2r]
        i_odd  = 2r + 2    # 1-based index of prev_level[2r+1]

        if i_odd > n_prev
            # ODD tail: pass through unchanged (paper Eq. 12 "n is odd")
            # Reuse the existing register, padded with zeros at top.
            orphan = prev_level[i_even]
            # Allocate new width out_width; copy with CNOTs; zeros stay zero.
            z = allocate!(wa, out_width)
            for j in 1:length(orphan)
                push!(gates, CNOTGate(orphan[j], z[j]))
            end
            push!(new_level, z)
            continue
        end

        A = prev_level[i_even]
        B = prev_level[i_odd]
        z = allocate!(wa, out_width)

        # Partition z:
        #   z[1..k]         = suffix (A's low k bits copied in)
        #   z[k+1..k+W]     = overlap sum (n-bit QCLA)
        #   z[k+W+1]        = carry-out of overlap
        #   z[k+W+2..out]   = high region (B's high k bits with carry propagation)
        #
        # At d=1, A has width W, B has width W. k = 1.
        # At d>=2, both A, B have width W + 2^{d-1} = W + k.

        z_suffix  = z[1:k]
        z_overlap = z[(k+1):(k+W)]
        z_carry   = z[k+W+1]
        z_high    = z[(k+W+2):out_width]   # length out_width - (k+W+1) = k-1

        # ---- suffix_copying ----
        for j in 1:k
            push!(gates, CNOTGate(A[j], z_suffix[j]))
        end

        # ---- overlapping_sum ----
        if d == 1
            a_mid = A[1:W]              # A[1..W]
            b_mid = B[1:W]
        else
            a_mid = A[(k+1):(k+W)]      # A[k+1 .. k+W]
            b_mid = B[1:W]              # B[1..W]
        end

        # n-bit out-of-place QCLA on (a_mid, b_mid) producing n+1 bits.
        # Result's low n bits CNOT-copied into z_overlap; top bit into z_carry.
        r = lower_add_qcla!(gates, wa, a_mid, b_mid, W)
        for j in 1:W
            push!(gates, CNOTGate(r[j], z_overlap[j]))
        end
        push!(gates, CNOTGate(r[W+1], z_carry))
        # Inverse of the QCLA to release r back to zero.
        _inverse_qcla!(gates, wa, a_mid, b_mid, W, r)
        free!(wa, r)

        # ---- carry_propagation ----
        if d == 1
            # k-1 = 0, nothing to do. The carry-out `z_carry` IS the top bit.
            # Note: z_high has length 0 here.
        else
            b_high = B[(W+1):(W+k)]     # B's high k bits
            _emit_carry_propagation!(gates, wa, z_carry, b_high, z_high, k - 1, W, out_width, z)
            # ^ propagates the carry through B[W+1..W+k], writing into z_high
            #   and z[out_width] (top bit).
        end

        push!(new_level, z)
    end

    return new_level
end


"""
    _emit_inverse_level!(gates, wa, consumed_level, producing_level, d, W)

Uncompute all adders at level d, zeroing every register in `producing_level`
(= levels[d+1]). `consumed_level` (= levels[d+2]) was produced FROM
producing_level and is still live; its wires were mutated by the forward
adders so we run each forward adder's gate sequence in reverse.
"""
function _emit_inverse_level!(gates, wa, consumed_level, producing_level, d, W)
    # Strategy: the forward pass for level d emitted a specific gate
    # sequence per adder; we replay those gates in reverse order.
    # BUT we didn't store them separately — they're intermixed in `gates`.
    #
    # Two implementation options:
    #   (a) Re-emit the forward level into a scratch Vector{ReversibleGate},
    #       reverse it, append. Costs 2× the gate memory transiently but
    #       is trivial to implement.
    #   (b) Track gate-index ranges per level and slice.
    #
    # Pick (a) — simpler, O(gates-per-level) scratch memory.

    scratch = Vector{ReversibleGate}()
    wa_snapshot = (wa.next_wire, copy(wa.free_list))   # REMEMBER: avoid wire-drift

    # Re-run the forward emission into scratch on the ORIGINAL inputs.
    # But the allocator state has drifted. We need a per-adder ancilla
    # bookkeeping strategy.

    # ... (see §6.1 below for correct inverse emission strategy)
end
```

### 6.1 Inverse emission strategy (subtle)

The naive "re-run level forward into scratch, reverse" fails because:
(1) the wire allocator's state has drifted between forward and inverse;
(2) the ancillae allocated during the forward pass are long-freed.

**Correct strategy:** during the forward pass, record the gate-index
range `[start, end]` for each level-d adder alongside the output register
`z`. Store these in a parallel structure (a `Dict{Int, Tuple{Int,Int}}`
mapping level-d adder index to gate-range). At inverse-emission time,
iterate the saved range in reverse and push each gate (reversed) into
`gates`:

```julia
# Forward emission (modified):
struct _AdderRecord
    level::Int
    r::Int
    gate_start::Int   # inclusive
    gate_end::Int     # inclusive
    output_reg::Vector{Int}
end

records = Vector{_AdderRecord}()

# ... inside _emit_one_level! ...
s = length(gates) + 1
# ... emit the adder ...
e = length(gates)
push!(records, _AdderRecord(d, r, s, e, z))

# Inverse emission:
function _emit_inverse_adder!(gates, record)
    for i in record.gate_end:-1:record.gate_start
        push!(gates, gates[i])   # each gate is self-inverse; just re-push in reverse order
    end
end
```

This works because every gate in {NOTGate, CNOTGate, ToffoliGate} is
self-inverse. Reversing the order of a gate list gives the inverse
circuit.

**BUT** the ancillae used inside the forward adder (via
`lower_add_qcla!` internal allocations) have been freed at this point.
The inverse gates reference those wire INDICES, but the allocator may
have handed them out to OTHER level-d adders in the meantime. This
creates aliasing.

**Solution: don't free intra-adder ancillae until the inverse level
runs.** Stash a per-record list of "wires this adder allocated but
hasn't explicitly freed yet". Free them only after `_emit_inverse_adder!`
runs. This increases peak ancilla by `O(2n)` per live adder — acceptable
within the `2n²` total budget.

Actually simpler: since adders within a level are emitted sequentially
(not in parallel in our linearized schedule), each adder's ancillae CAN
be freed and reused by the next adder at the SAME level. The only
wires that must persist are the OUTPUT registers (`z`), which are live
until level `d+1` consumes them (or longer for level D's root). So the
wire reservation rule is:
- Free intra-adder ancillae at the end of each adder's forward block.
- Do NOT reuse them for other level-d adders' *outputs*.
- When inverting the adder, allocate FRESH ancillae (or re-use via
  free-list). Since the adder's gate sequence is self-inverse, running
  it with a different wire-index mapping still produces a valid
  inverse computation IF the wires satisfy the same zero-state
  precondition.

**This is subtle.** Let me think again.

Bennett's construction: forward, copy, uncompute. The uncompute reads
and re-emits the forward gate list in reverse. The wire INDICES must
match across forward and reverse — which they do, because the gate
list references wire indices, not wire "identities". Bennett.jl's
`bennett.jl` does this naturally.

For our linearized `emit_parallel_adder_tree!`: we emit adders
sequentially. When inverting an adder at level d, we must replay its
gates in reverse WITH THE SAME WIRE INDICES. So we save the gate-range
`[s, e]` as above, and replay:

```julia
for i in record.gate_end:-1:record.gate_start
    push!(gates, gates[i])
end
```

The wires referenced in `gates[i]` are specific indices that were live
at the time of forward emission. At inverse emission time, are those
wires STILL live (holding the right state)?

- `z` (output register): YES, still live — we haven't freed it.
- Intra-adder ancillae (inside `lower_add_qcla!`): these were freed
  at the end of the forward adder block. The allocator may have
  handed them out to someone else.

**Escape hatch:** before freeing the intra-adder ancillae, we stash
them in the `_AdderRecord`. We DON'T call `free!` on them at end of
forward. We DO call `free!` on them at end of inverse.

```julia
struct _AdderRecord
    level::Int; r::Int
    gate_start::Int; gate_end::Int
    output_reg::Vector{Int}
    internal_wires::Vector{Int}   # ancillae inside this adder
end

# Forward:
wa_checkpoint = wa.next_wire
# ... emit forward adder ...
wa_final = wa.next_wire
internal = collect(wa_checkpoint:wa_final-1) # NEW wires allocated during forward
# DON'T free them yet.

# Inverse:
_replay_reverse!(gates, record.gate_start, record.gate_end)
# Now the internal wires are zero again. Free them.
free!(wa, record.internal_wires)
```

This is the cleanest correct story. Cost: level-d ancillae don't reuse
within level d, increasing peak-live by up to `(n / 2^d) · (n − w(n) −
⌊log n⌋) ≤ (n²) / 2^d`. Summed: `n²`. So peak live grows by at most
`n²`, keeping total below `3n²` (paper claims `2n²`).

**This is a `2×` to `3×` regression from the paper's bound.** We flag it
in the design and fix in follow-up Bennett-??? ("parallel_adder_tree
ancilla tightening").

### 6.2 Final pseudocode (condensed)

```julia
function emit_parallel_adder_tree!(gates, wa, pps, W; freed_ancilla=Int[])
    # Preconditions
    W >= 1 || error("W must be >= 1")
    length(pps) == W || error("pps length mismatch")
    for pp in pps; length(pp) == W || error("pp width mismatch"); end

    # Recycle freed pool
    isempty(freed_ancilla) || free!(wa, freed_ancilla)

    # Degenerate: W = 1
    if W == 1
        result = allocate!(wa, 2)
        push!(gates, CNOTGate(pps[1][1], result[1]))
        return result
    end

    D = ceil(Int, log2(W))
    levels = Vector{Vector{Vector{Int}}}(undef, D + 1)
    records = Vector{Vector{_AdderRecord}}(undef, D + 1)
    levels[1] = pps
    records[1] = _AdderRecord[]   # leaves have no records

    # Forward, linearized uncompute-in-flight
    levels[2] = Vector{Vector{Int}}()
    records[2] = Vector{_AdderRecord}()
    _emit_one_level!(gates, wa, levels[1], 1, W, levels[2], records[2])

    if D >= 2
        levels[3] = Vector{Vector{Int}}()
        records[3] = Vector{_AdderRecord}()
        _emit_one_level!(gates, wa, levels[2], 2, W, levels[3], records[3])
    end

    for d in 3:D
        # Uncompute level d-2
        for rec in reverse(records[d-1])
            _replay_reverse!(gates, rec.gate_start, rec.gate_end)
            free!(wa, rec.internal_wires)
            free!(wa, rec.output_reg)
        end
        empty!(levels[d-1])
        empty!(records[d-1])

        # Compute level d
        levels[d+1] = Vector{Vector{Int}}()
        records[d+1] = Vector{_AdderRecord}()
        _emit_one_level!(gates, wa, levels[d], d, W, levels[d+1], records[d+1])
    end

    # Final cleanup: uncompute level D-1
    if D >= 2
        for rec in reverse(records[D])
            _replay_reverse!(gates, rec.gate_start, rec.gate_end)
            free!(wa, rec.internal_wires)
            free!(wa, rec.output_reg)
        end
    end

    # Only level D remains: xy.
    return levels[D+1][1]
end
```

Helper `_replay_reverse!`:

```julia
function _replay_reverse!(gates::Vector{ReversibleGate}, s::Int, e::Int)
    for i in e:-1:s
        push!(gates, gates[i])
    end
end
```

---

## 7. Cost formulas

All formulas from paper §II.D.4. Let `n = W`.

### 7.1 overlapping_sum contribution

Each overlap is an `n`-bit QCLA. Per QCLA consensus doc:
- Toffolis: `5n − 3w(n) − 3⌊log₂ n⌋ − 1` per call.
- CNOTs: `3n − 1` per call.
- Toffoli-depth: `⌊log₂ n⌋ + ⌊log₂(n/3)⌋ + 4` per call.

Number of overlap calls: at level `d`, `⌈n / 2^d⌉` adders, each with one
overlap. Including uncompute-in-flight, each level's overlap is run TWICE
(forward + inverse). Total calls across all levels:

```
Σ_{d=1}^{D} (⌈n / 2^d⌉) · 2 = 2 · (n − 1) ≈ 2n
```

(The `-1` accounts for `D = log₂ n` levels with `n/2, n/4, …, 1` adders.)

So total Toffolis from overlap: `2n · (5n − 3w(n) − 3 log n) ≈ 10n²`.

### 7.2 carry_propagation contribution

At level `d`, each adder's carry_propagation runs a QCLA at width
`k = 2^{d-1}`, plus 2 CNOTs, plus inverse. Total across all levels:

```
Σ_{d=1}^{D} (⌈n / 2^d⌉) · (5 · 2^{d-1} − 3·…) · 2
≈ Σ_{d=1}^{D} (n / 2^d) · (5 · 2^{d-1}) · 2
= Σ_{d=1}^{D} (5n / 2) = (5n/2) · log n = O(n log n)
```

Small potatoes. Paper's `− n log n` term in Eq. 26 is SUBTRACTED (savings
from not doing certain operations), so our `+ O(n log n)` from
carry_propagation overhead puts us right at the paper's bound.

### 7.3 suffix_copying contribution

Zero Toffolis, `O(n log n)` CNOTs total (each level contributes `n/2`
CNOTs; `log n` levels). Doubled by uncompute.

### 7.4 Totals

| Metric            | Formula (paper)              | Ours target         |
|-------------------|------------------------------|---------------------|
| Toffolis          | `10n² − n log n`             | same ±10%           |
| Toffoli-depth     | `3 log² n + 7 log n + 12`    | up to `2×` (linearized) |
| Total gates       | `16n² + 2n log n`            | same ±10%           |
| Ancilla           | `≤ 2n²` for `n ≥ 6`          | `≤ 3n²` (see §6.1)  |
| Peak-live wires   | `≤ 2n²`                      | `≤ 3n²`             |

We document the `3n²` vs `2n²` regression in the WORKLOG and file a
follow-up bd issue for tightening (analogous to the `timeslice fusion`
QCLA deferral).

### 7.5 Concrete numbers at W = 8

- overlapping_sum QCLA: `n=8` → 27 Toffolis, 23 CNOTs (per call).
- Adders at level 1: 4; level 2: 2; level 3: 1. Total: 7.
- Toffolis from overlap: `7 · 27 · 2 = 378` (factor 2 for uncompute).
- Toffolis from carry_propagation: `~40` (rough estimate).
- Total Toffolis at W=8: `~420`. Paper formula `10·64 − 8·3 = 616`.
  We're BELOW the paper's bound, which makes sense — the paper is an
  UPPER bound.
- Ancilla at W=8: ≤ 3 · 64 = 192 wires peak.

---

## 8. Worked W=4 example

For `W = 4, n = 4, D = 2`.

### 8.1 Tree structure

```
Level 0 (leaves):  α^(0,0), α^(0,1), α^(0,2), α^(0,3)     each 4 bits
                       \    /               \    /
                        Add_1                Add_1
                         |                    |
Level 1:             α^(1,0)              α^(1,1)         each 6 bits = 4 + 2
                            \            /
                              Add_2
                               |
Level 2 (root):            α^(2,0) = xy                      8 bits = 4 + 4
```

### 8.2 Level 1 adders (d=1, k=1)

Each `Add_1` sums `α^(0,2r) + 2 · α^(0,2r+1)`. Output width `4 + 2 = 6`.

For `α^(1,0) = α^(0,0) + 2 · α^(0,1)`:
- Allocate `z` of width 6.
- suffix_copying: `z[1] ⊕= α^(0,0)[1]` (single CNOT).
- overlapping_sum: 4-bit QCLA on `(α^(0,0)[1:4], α^(0,1)[0:3])`. Wait —
  at `d=1, k=1`, `a_mid = A[1:W] = α^(0,0)[1:4]`. But I earlier said at
  `d=1`, `a_mid = A[1:W]`. Let me re-check.

Actually at `d=1`: both A and B are leaves with width `n = W = 4`. The
level-1 output has width `n + 2 = 6`. The suffix_copying copies `A`'s
low `k = 1` bit; the overlap is `n = 4` bits; the carry-propagation is
`k - 1 = 0` bits + 1 bit (the overflow) = 1 bit.

Wait — that's wrong. At `d=1`, `k=1`, carry_propagation width is
`k = 1`. Re-read the paper's partition: output width `n + 2k = n + 2`.
Low `k = 1` bit = suffix; next `n = 4` bits = overlap; last `k = 1`
bit = carry_propagation's domain.

But carry_propagation with `k = 1`: we have 1 bit of B's high region
(i.e., `B[n + 1 - 1] = B[n] = B[4] = nothing — B has only 4 bits`).

**Conflict detected!** At `d = 1`, the leaves have width `n = 4`, but
my partition assumes `B` has width `n + k = n + 1 = 5`. Only true at
`d ≥ 2`.

**Fix:** At `d = 1`, `B` has width `n` (not `n + k`). The high region
is width `k - 1 = 0` (no B[n+1..n+k-1] bits). The carry_propagation
is only the overflow bit from overlap.

Revised at `d = 1`:
- `z[1]` = suffix (A[1]): 1 CNOT
- `z[2..5]` = overlap (A[1..4] + B[1..4]): 4-bit QCLA, LSB matches
  paper indexing... hmm wait.

Hmm, `a_mid` and `b_mid` both have width `n`, starting from position 0
(paper-index). At `d = 1`, `A = α^(0, 2r)` is of width `n`; there's
no "bits above n" in A. So `a_mid = A` entirely, and the output of
overlap's low `n` bits goes to `z[k+1..k+n] = z[2..n+1] = z[2..5]`.
The overlap's top bit (overflow) goes to `z[k + n + 1] = z[n + 2] =
z[6]`. Width is `n + 2 = 6`. All 6 bits accounted for.

So at `d = 1`:
- suffix: 1 CNOT onto z[1]
- overlap: 4-bit QCLA on (A, B); result length 5; CNOT-copy low 4 into
  z[2..5]; CNOT top bit into z[6]
- carry_propagation: EMPTY (no high-region bits to propagate into)
- z[6] holds the overflow, which is the sum bit for position 5.

Ah — at `d = 1` the overlap's carry-out IS the top bit of the output.
No carry_propagation needed. 

At `d ≥ 2`, both operands have width `n + k`. `A`'s low `k` bits go to
suffix; `A`'s mid `n` bits go to overlap with `B`'s low `n` bits; `B`'s
high `k` bits go into carry_propagation along with the overlap carry.

Let me re-verify the widths:
- `a_mid` at `d ≥ 2`: `A[k+1..k+n]` has width `n`.
- `b_mid` at `d ≥ 2`: `B[1..n]` has width `n`.
- Overlap output: `n + 1` bits → low `n` into `z[k+1..k+n]`, top into
  `z[k+n+1]`.
- carry_propagation: combines `z[k+n+1]` (overlap overflow) with
  `B[n+1..n+k]` (B's high `k` bits, width `k`). Output width `k`, goes
  into `z[k+n+1..k+n+k] = z[k+n+1..n+2k]`. Wait — that reuses
  `z[k+n+1]`. So the carry_propagation's output LOW bit IS the overlap
  overflow. That's consistent.

OK clarified. Back to the W=4 example.

### 8.3 Level 1: `α^(1,0) = α^(0,0) + 2·α^(0,1)`

- Allocate `z = allocate!(wa, 6)`.
- suffix: `CNOT(α^(0,0)[1], z[1])`.
- overlap: call `lower_add_qcla!(gates, wa, α^(0,0), α^(0,1), 4)` →
  produces `r` of length 5. Then:
  - `CNOT(r[1], z[2])`, `CNOT(r[2], z[3])`, `CNOT(r[3], z[4])`,
    `CNOT(r[4], z[5])`, `CNOT(r[5], z[6])`.
- Inverse QCLA to uncompute `r`: replay the forward QCLA's gates in
  reverse, zeroing `r`.
- No carry_propagation at `d=1`.

Per-adder cost: QCLA (27 Toffolis at W=4? no, at n=4 it's 10 Toffolis
per consensus table) + inverse = 20 Toffolis. Plus 6 CNOTs. So
`α^(1,0)` costs ~20 Toffolis, ~18 CNOTs. `α^(1,1)` same.

### 8.4 Level 2: `α^(2,0) = α^(1,0) + 4·α^(1,1)`

Here `d = 2, k = 2, n = 4`. Both operands have width `n + k = 6`. The
output width is `n + 2k = 8 = 2W`. 

- Allocate `z = allocate!(wa, 8)`.
- suffix: `CNOT(α^(1,0)[1], z[1])`, `CNOT(α^(1,0)[2], z[2])` (`k = 2`
  CNOTs).
- overlap: 4-bit QCLA on `(α^(1,0)[3..6], α^(1,1)[1..4])` (both width
  `n = 4`). Result length 5. CNOT-copy low 4 into `z[3..6]`, top into
  `z[7]`.
- Inverse QCLA.
- carry_propagation: combine `z[7]` (overlap carry) with
  `α^(1,1)[5..6]` (B's high 2 bits, width `k = 2`). Output width `k = 2`
  goes into `z[7..8]`.
  - Allocate temp `q = allocate!(wa, 2)`.
  - `CNOT(z[7], q[1])` — now `q = [carry, 0]`.
  - `r = lower_add_qcla!(gates, wa, α^(1,1)[5..6], q, 2)` → length 3.
  - `CNOT(r[1], z[7])` (this OVERWRITES z[7] since q was derived from
    it — but the QCLA's output is `a_mid + q`, so `r[1] = α^(1,1)[5] ⊕
    carry` which is the corrected low bit of the high region).

    Hmm — `z[7]` was holding the carry. After this CNOT, `z[7] ⊕= r[1]`,
    which turns `z[7]` into `carry ⊕ α^(1,1)[5] ⊕ carry = α^(1,1)[5]`.
    That's WRONG — we wanted `z[7]` to hold the sum bit
    `α^(1,1)[5] + carry`.

Oh — the issue is that `z[7]` is both the source of `q[1]` AND the
target of the CNOT-copy. We need to allocate a SEPARATE output region
or handle this more carefully.

**Fix:** After the QCLA produces `r`, zero `z[7]` first (uncompute the
`CNOT(z[7], q[1])`), THEN CNOT `r[1]` onto `z[7]`. Or equivalently,
since `z[7]` already holds `carry` and we need it to become `carry ⊕
α^(1,1)[5] = r[1]`, we CNOT `α^(1,1)[5]` onto `z[7]` directly — but
then the outer `r` is computed on `(α^(1,1)[5..6], [carry, 0])` which
has the carry INSIDE the QCLA, and `r[1] = α^(1,1)[5] ⊕ carry = sum`.
That's the same thing.

Actually the simplest clean story: allocate `z_high_workspace` separately
from `z`, run the QCLA, CNOT-copy into `z[7..8]` (which already hold
`[carry, 0]`), then uncompute.

```
# z[7] already holds carry (from overlap's overflow); z[8] = 0
q = allocate!(wa, 2)
CNOT(z[7], q[1])     # q = [carry, 0]
r = lower_add_qcla!(gates, wa, α^(1,1)[5..6], q, 2)   # r = 3 wires
# r[1] = α^(1,1)[5] + q[1] (mod 2) = α^(1,1)[5] ⊕ carry
# r[2] = α^(1,1)[6] + carry_1_to_2 + 0
# r[3] = carry_out

# Now CNOT r back into z. z[7] currently = carry. We want z[7] = r[1].
# r[1] = α^(1,1)[5] ⊕ carry, so we CNOT α^(1,1)[5] onto z[7]:
CNOT(α^(1,1)[5], z[7])   # z[7] ← carry ⊕ α^(1,1)[5] = r[1] ✓
# No, wait — r[1] could have an additional ripple carry from higher bits
# if α^(1,1)[5] wraps... no, r[1] is the LSB of the sum so it's just
# XOR with no carry-in.

# Use: CNOT(r[1], z[7]) — but z[7] starts as carry, so z[7] ⊕= r[1] =
# carry ⊕ (α^(1,1)[5] ⊕ carry) = α^(1,1)[5]. Wrong.

# Correct: zero z[7] first (inverse of CNOT(overlap_carry, z[7])),
# then CNOT r[1] onto z[7]. But overlap_carry is a separate wire (the
# QCLA's result[W+1]), which we already CNOT-copied INTO z[7] earlier.
# To zero z[7] we CNOT that source again, which requires it to still
# be live. It IS, because we hold `result` from overlap until after
# carry_propagation is done.

# Simpler: don't CNOT-copy overlap_carry into z[7] until AFTER
# carry_propagation. Pass overlap_carry directly to carry_propagation.
```

Let me redo the partitioning:

```
After overlap:
  overlap_result = r (length W+1)
  # r[1..W] = sum bits; r[W+1] = carry-out

# Don't CNOT overlap_result into z yet; keep it live.

After carry_propagation:
  # carry_propagation produces the high-k-bit sum given (B_high, carry)
  cp_result = ...  (length k+1, e.g. r' of inverse QCLA)
  # cp_result[1] is the LSB of the high-region sum
  # cp_result[k+1] is the overall overflow (for internal levels, goes
  #   into z[last])

# Then CNOT-copy everything into z:
for j in 1:W
    CNOT(overlap_result[j], z[k + j])
end
for j in 1:k
    CNOT(cp_result[j], z[k + W + j])
end
# Note: cp_result[1] and overlap_result[W+1] are BOTH the low bit of
# the high region. They must AGREE, which they do if
# cp_result[1] = overlap_carry ⊕ B_high[1].

# Uncompute overlap and carry_propagation in reverse.
```

This is cleaner: keep both intermediate results live, then do all the
CNOT-copies at the end, then uncompute in reverse.

Revised adder structure:

```julia
function _emit_one_adder!(gates, wa, A, B, d, W)
    k = 1 << (d-1)
    out_w = W + 2k
    z = allocate!(wa, out_w)

    # 1. suffix_copying
    for j in 1:k
        push!(gates, CNOTGate(A[j], z[j]))
    end

    # 2. overlapping_sum (produces r of length W+1)
    a_mid = d == 1 ? A : A[k+1:k+W]
    b_mid = B[1:W]
    r = lower_add_qcla!(gates, wa, a_mid, b_mid, W)

    # 3. carry_propagation (d ≥ 2 only)
    local cp_result
    if d >= 2
        b_high = B[W+1:W+k]
        # Run a k-bit out-of-place QCLA on (b_high, q) where q =
        # [r[W+1], 0, ..., 0].
        q = allocate!(wa, k)
        push!(gates, CNOTGate(r[W+1], q[1]))
        cp_result = lower_add_qcla!(gates, wa, b_high, q, k)
        # cp_result length k+1; cp_result[k+1] is the high overflow
    end

    # 4. CNOT-copy results into z
    for j in 1:W
        push!(gates, CNOTGate(r[j], z[k+j]))
    end
    if d >= 2
        for j in 1:k
            push!(gates, CNOTGate(cp_result[j], z[k+W+j-1+1]))
            # carefully: z[k+W+1 .. k+W+k] = z[k+W+1 .. out_w]
        end
        push!(gates, CNOTGate(cp_result[k+1], z[out_w]))
        # ... but z[k+W+k+1] = z[out_w+1] — off by one!
    else
        push!(gates, CNOTGate(r[W+1], z[k+W+1]))  # d=1: top bit is the overflow
    end

    # 5. Uncompute
    if d >= 2
        _inverse_qcla!(gates, wa, b_high, q, k, cp_result)
        push!(gates, CNOTGate(r[W+1], q[1]))   # undo step 3's CNOT
        free!(wa, q)
        free!(wa, cp_result)
    end
    _inverse_qcla!(gates, wa, a_mid, b_mid, W, r)
    free!(wa, r)

    return z
end
```

I still need to double-check the wire indexing in step 4 for `d ≥ 2`.
Width `out_w = W + 2k`. Slots:
- `z[1..k]`: suffix (written in step 1)
- `z[k+1..k+W]`: overlap low bits (written in step 4 from `r[1..W]`)
- `z[k+W+1..k+W+k] = z[k+W+1..out_w]`: high region (written in step 4
  from `cp_result[1..k]`)

`cp_result` has length `k+1`. Its last bit `cp_result[k+1]` is the
overall overflow. At internal levels this overflow MUST be zero (we
sized the output to fit exactly) — it's zero because `α^(d-1, 2r) + 2^k
· α^(d-1, 2r+1)` fits in `n + 2k` bits with no slack. Paper's Claim 2
guarantees this.

But wait — `cp_result[k+1]` being zero is a runtime guarantee, not
compile-time. When we CNOT `cp_result[k+1]` onto `z[out_w+1]`... but
there's no `z[out_w+1]`. We shouldn't emit that CNOT.

**Resolution:** assert that `cp_result[k+1] == 0` always (Claim 2
invariant). Do NOT allocate a slot for it. The `_inverse_qcla!` call
uncomputes it to zero as part of the inverse — so it must HAVE been
zero or the inverse would fail.

Actually this reveals a subtlety: `lower_add_qcla!` produces a `(k+1)`-bit
result register that it allocates. The top bit is sometimes 0 (when the
sum fits) and sometimes 1 (when there's overflow). The inverse QCLA
must be called symmetrically — it will uncompute whatever was produced.

So we just DON'T CNOT-copy `cp_result[k+1]`. It stays on the `cp_result`
wire, gets uncomputed by `_inverse_qcla!`, and the wire is freed.

At level d = D, though, we want the top bit. But at d = D, the output is
`2W` bits = `n + 2^D`, and the top bit is `α^(D, 0)`'s MSB. Whether it
overflows depends on whether `xy ≥ 2^{2n-1}` — for full `n×n = 2n`-bit
multiplication without truncation, the MSB can be either 0 or 1. So
`cp_result[k+1]` at d = D is nontrivially either 0 or 1.

BUT: at d = D, `k = 2^{D-1} = n/2` (if n is a power of 2). The output
is `n + 2k = 2n`. The partition is `z[1..k]` suffix, `z[k+1..k+n]`
overlap (n bits), `z[k+n+1..2n]` carry-propagation (k bits). Top bit
`z[2n]` is inside the carry-propagation region, slot `k`. That
corresponds to `cp_result[k]`, not `cp_result[k+1]`. So
`cp_result[k+1]` is one slot ABOVE the output register — and IT
carries information at d = D.

**Wait.** At d = D, the arithmetic is `α^(D-1, 0) + 2^{n/2} · α^(D-1, 1)`.
Both operands have width `n + n/2 = 3n/2`. Output width should be
`max(3n/2, 3n/2 + n/2) + 1 = 2n + 1`? No — `2^{n/2} · α^(D-1, 1)`
has at most `3n/2 + n/2 = 2n` bits. Plus `α^(D-1, 0)` of `3n/2` bits.
Sum at most `2n` bits + 1 carry = `2n + 1` bits. But Claim 2 says
output width is `n + 2^D = 2n` (no extra slot).

Claim 2 says "each partial sum has at most `n + 2^d` bits". At d = D
this is `2n`. How is the `2n+1`-bit arithmetic fit in `2n` bits?

Because `x y < 2^n · 2^n = 2^{2n}`, i.e., `xy` fits in `2n` bits. The
partial sums up to `α^(D, 0) = xy` are bounded by `xy < 2^{2n}`. So the
final sum doesn't overflow `2n` bits. At d = D, `cp_result[k+1]` is
ALWAYS zero (by the bound).

At internal levels d < D, `cp_result[k+1]` can be nonzero? Let's check.
At level d, `α^(d, r)` could be as large as `2 · max(α^(d-1))`. If
`α^(d-1, 2r)` and `α^(d-1, 2r+1)` each fit in `n + 2^{d-1}` bits, their
sum (shifted) fits in `n + 2^d` bits. So `α^(d, r) < 2^{n + 2^d}`, no
overflow. `cp_result[k+1]` is always zero at internal levels too.

Good. So we never need to emit a CNOT on `cp_result[k+1]`. The
`_inverse_qcla!` uncomputes it to zero (since it was zero to start
with, the inverse trivially restores zero).

### 8.5 Trace for `α^(2,0) = α^(1,0) + 4 · α^(1,1)` at W=4

Widths: A, B = 6 each. k = 2. out_w = 8. z = 8 wires.

- suffix: `CNOT(A[1], z[1])`, `CNOT(A[2], z[2])`.
- overlap: `lower_add_qcla!(A[3..6], B[1..4], 4)` → `r` of length 5.
- carry_propagation:
  - `q = allocate!(2)` = [0, 0].
  - `CNOT(r[5], q[1])` → q = [carry, 0].
  - `cp_result = lower_add_qcla!(B[5..6], q, 2)` → length 3.
- CNOT-copy:
  - `CNOT(r[1], z[3])`, `CNOT(r[2], z[4])`, `CNOT(r[3], z[5])`,
    `CNOT(r[4], z[6])`.
  - `CNOT(cp_result[1], z[7])`, `CNOT(cp_result[2], z[8])`.
  - (cp_result[3] is zero by Claim 2; don't touch.)
- Uncompute:
  - `_inverse_qcla!(B[5..6], q, 2, cp_result)` — zeroes `cp_result` and
    restores `q` to its pre-QCLA state.
  - `CNOT(r[5], q[1])` → restores q to [0,0].
  - `free!(wa, q)`.
  - `free!(wa, cp_result)`.
  - `_inverse_qcla!(A[3..6], B[1..4], 4, r)` — zeroes `r`.
  - `free!(wa, r)`.

Final state: z holds xy. All ancillae zero. A, B unchanged. Good.

### 8.6 Wire uncompute schedule at W=4

```
Forward:
  level 1 compute α^(1,0), α^(1,1)   (Add_1 × 2)
  level 2 compute α^(2,0)            (Add_2)

Uncompute (since D = 2, main loop doesn't execute, and D ≥ 2 triggers
the final uncompute of level D-1 = 1):
  level 1 uncompute α^(1,0), α^(1,1)
```

Wait — the main loop runs `for d in 3:D`. With D = 2, the loop is
empty. Then the "final cleanup" block at D ≥ 2 uncomputes level D−1 = 1.

What about level 0? We don't uncompute it — those are the input partial
products, the caller handles them. Good.

Result: z_level2[0] = xy; all other levels' wires are zero-and-freed.

Peak live:
- During level 1: `α^(0, *)` (4 · 4 = 16 wires) + `α^(1, 0)` (6) + QCLA
  ancilla for Add_1 (~1 + ~5 = 6 wires during overlap). Peak ≈ 28.
- During level 2: `α^(0, *)` (16) + `α^(1, *)` (12) + `α^(2, 0)` (8) +
  QCLA ancilla (~6). Peak ≈ 42.
- After level 2: same, minus Add_2's ancilla.
- During uncompute of level 1: `α^(0, *)` (16) + `α^(1, *)` (12) + `α^(2, 0)`
  (8) + inverse-QCLA ancilla (~6). Peak ≈ 42.

Total ≈ 42 = ~2.6 × n² = 2.6 × 16 = 42. Close to 3n² bound. OK.

---

## 9. Test plan

`test/test_parallel_adder_tree.jl`:

### 9.1 Unit tests (RED-first)

1. **W = 2 exhaustive.** Two 2-bit partial products α^(0,0), α^(0,1).
   Each in {0,1,2,3}. 4 × 4 = 16 cases. For each `(α0, α1)` the expected
   `xy = α0 + 2·α1`. Verify output matches.

2. **W = 4 exhaustive.** Four 4-bit partial products. Each in {0..15}.
   16⁴ = 65,536 cases. For each, expected `xy = α0 + 2·α1 + 4·α2 + 8·α3`.
   Verify output matches.

   NOTE: these are NOT exhaustively over xy; they're exhaustively over
   the 4-tuple of α^(0,i). But the α^(0,i) must be CONSISTENT with some
   (x, y) — i.e., α^(0,i) = y_i · x. For the adder tree test ALONE, we
   don't require consistency; we just verify the summation is correct
   for arbitrary 4-tuples. Later integration tests verify consistency
   with `emit_partial_products!`.

   Exhaustive over arbitrary 4-tuples is 65,536 cases, which is
   tractable.

3. **W = 8 sampled.** 1000 random 8-tuples of 8-bit values; verify
   `∑ 2^i α_i == xy`.

4. **Ancilla-zero invariant.** After running any of the tests, the
   wire-vector is all zero EXCEPT the `|xy>` output register. Use
   `verify_reversibility` style check.

5. **Gate-count regression pin (principle 6).** Exact Toffoli count,
   total gate count, Toffoli-depth at W = 4, 8. Store as baselines in
   `test_gate_count_regression.jl`.

6. **Ancilla count ≤ 3n²** for n = 8, 16, 32 (our relaxed target).
   Assert and document the gap to the paper's 2n² bound.

7. **Full-circuit integration with partial_products.** Compose:
   `emit_fast_copy → emit_partial_products → emit_parallel_adder_tree →
   uncompute`. Exhaustive W = 4 multiplication (256 `(x, y)` pairs),
   result must match `x * y`.

8. **Edge: W = 1 degenerate.** Single partial product; output is that
   product zero-padded to 2 bits. Verify.

9. **Edge: W = 3, 5, 6, 7 (non-power-of-2).** Odd orphan handling.

### 9.2 Integration tests (deferred to X-phase)

- `reversible_compile(x -> x*y, Int8, Int8; mul=:qcla_tree)` — smoke
  test of end-to-end mul via dispatcher. (This belongs to Phase X, not
  Phase A.)

### 9.3 Baseline for principle 6

After GREEN, pin Toffoli counts for W ∈ {4, 8, 16, 32} in WORKLOG.md
and `test_gate_count_regression.jl`. Any future change touching
`parallel_adder_tree.jl` that shifts these counts triggers investigation.

---

## 10. Edge cases

### 10.1 `W = 1`

No tree needed. The single partial product α^(0,0) IS `xy` (up to
zero-padding to `2W = 2` bits). Handle explicitly in
`emit_parallel_adder_tree!`:

```julia
if W == 1
    result = allocate!(wa, 2)
    push!(gates, CNOTGate(partial_products[1][1], result[1]))
    return result
end
```

### 10.2 `W = 2`

`D = 1`, one adder at level 1. Output is `α^(0,0) + 2·α^(0,1)` = `4`-bit
sum. No main loop, no uncompute (nothing to uncompute). Direct.

### 10.3 `W = 3, 5, 6, 7` (non-power-of-2)

`D = ⌈log₂ W⌉`. At some level the count of previous partial sums is odd
(e.g., W = 3 → level 1 has 2 adders on pair (0,1); pair (2) is an orphan
passed through unchanged, wrapped to appear at level 1 as a single
register of width `n + 2^1 = n + 2` with the orphan's data in the low
`n` bits and zeros at top).

Our forward loop handles this:

```julia
for r in 0:(n_new - 1)
    i_even = 2r + 1
    i_odd  = 2r + 2
    if i_odd > n_prev
        # orphan pass-through
        ...
        continue
    end
    # normal adder emission
end
```

This adds `out_width` CNOTs per orphan (widening with zero padding). On
uncompute, the orphan is uncomputed by the outer tree iff the pass-through
was recorded as a "record" — we emit a fake record with a gate-range for
the CNOTs so that inverse replays zero them.

### 10.4 Very small `W` (1, 2, 3)

All handled above. `W = 1` via direct shortcut. `W ≥ 2` via the main
path.

### 10.5 Error paths

- `W < 1`: `error("W must be >= 1, got $W")`.
- `length(partial_products) != W`: `error(...)`.
- `partial_products[i]` wrong width: `error(...)`.
- `freed_ancilla` contains wire indices ≥ `wa.next_wire` (not yet
  allocated): `error("freed_ancilla contains unallocated wire")`.
- `freed_ancilla` contains duplicates: `error("freed_ancilla has
  duplicate wires")`.

All crash-loud per principle 1.

### 10.6 Interplay with outer `bennett()`

If the user wraps this in a standard `bennett()` construction, our
uncompute-in-flight is redundant: Bennett's outer wrap would uncompute
everything anyway. The paper's Algorithm 3 is a manually-written forward
+ cleanup sequence; `self_reversing = true` tells the Bennett wrap to
skip its own uncompute.

For the `parallel_adder_tree` submodule in isolation, we're NOT self-
reversing — the result register is LEFT LIVE, so Bennett's outer wrap
would correctly uncompute it. But inside `lower_mul_qcla_tree!` (Phase
X), the broader algorithm is self-reversing; `parallel_adder_tree` is
one step in the middle.

Decision: `emit_parallel_adder_tree!` does its own intermediate-level
uncompute (in-flight) but LEAVES the root register `α^(D,0) = xy` live.
Any outer wrap sees one live output register; clean contract.

---

## Summary of key design decisions

1. **Linearized uncompute-in-flight (§3).** Emit each level sequentially;
   between levels, uncompute `d − 2` before computing `d`. Accept 2×
   Toffoli-depth vs paper; Toffoli-COUNT is exactly paper's bound.

2. **Strategy α for carry_propagation (§2.2).** Fresh `k`-zero register
   + standard QCLA black box + CNOT-copy + inverse QCLA + free. Cleaner
   than the paper's "fan-out into output register" trick; costs O(k) extra
   per adder, total O(n log n) overhead — inside paper's headroom.

3. **Out-of-place everywhere; leave root live (§5, §10.6).** Result
   register `α^(D,0)` is the only live output on exit. All intermediate
   levels uncomputed.

4. **`_AdderRecord` with gate-range for inverse replay (§6.1).** Every
   forward adder saves its gate range `[s, e]` and ancilla wires.
   Inverse is `for i in e:-1:s; push!(gates, gates[i]); end` — trivially
   correct because all gates are self-inverse.

5. **Ancilla is `≤ 3n²` vs paper's `2n²` (§6.1, §7.4).** Known slack due
   to per-adder ancilla pinning until inverse runs. Documented.
   Follow-up bd issue will tighten.

6. **Explicit handling of W = 1, 2, 3, and non-power-of-2 (§10).** Fail-
   fast on malformed inputs; degenerate W handled without adders.
