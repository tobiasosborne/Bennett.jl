# Donald Knuth's Review of Bennett.jl

*A review in the style of The Art of Computer Programming, applied to the Bennett.jl reversible circuit compiler.*

---

## Opening Remarks

I have examined the source code of Bennett.jl with the care I would give to a
chapter of TAOCP. Let me begin with an observation that sets the right frame:
this project attempts something that has not been done before in a published,
tested system --- namely, the compilation of arbitrary LLVM IR (including
multi-way phi nodes from complex control flow graphs, IEEE 754 floating-point
special cases, and bounded loop unrolling) into verified reversible circuits via
Bennett's 1973 construction. The ambition is admirable. The execution is, in
many places, correct. In several places it is not, or is correct only by
accident.

I shall proceed systematically.

---

## 1. Algorithmic Correctness Assessment

### 1.1 Ripple-Carry Adder (`adder.jl`, lines 1--16)

The `lower_add!` function implements a ripple-carry full adder. Let me trace
the computation for W-bit addition of a[1:W] + b[1:W].

For each bit position i (1-indexed, LSB first):

1. `result[i] ^= a[i]` (CNOT)
2. `result[i] ^= b[i]` (CNOT)
3. If i < W: `carry[i+1] ^= a[i] & b[i]` (Toffoli)
4. If i < W: `carry[i+1] ^= result[i] & carry[i]` (Toffoli)
5. `result[i] ^= carry[i]` (CNOT)

After steps 1--2: result[i] = a[i] XOR b[i].
After step 3: carry[i+1] has a[i] AND b[i].
After step 4: carry[i+1] has a[i]&b[i] XOR (a[i] XOR b[i])&carry[i].

This is the standard full-adder carry: c_{i+1} = a_i b_i + (a_i XOR b_i) c_i,
which is the majority function MAJ(a_i, b_i, c_i). Correct.

After step 5: result[i] = a[i] XOR b[i] XOR carry[i], which is the sum bit. Correct.

The carry wires start at zero (freshly allocated), so carry[1] = 0. Correct
initial condition.

**Gate count**: Per bit: 2 CNOT + 2 Toffoli + 1 CNOT = 3 CNOT + 2 Toffoli
(for i < W), or 3 CNOT + 0 Toffoli (for i = W). Total for W bits:
3W CNOT + 2(W-1) Toffoli. For W = 8: 24 CNOT + 14 Toffoli = 38 gates for the
adder alone. This is consistent with the documented 86 total gates for `x + 1`
on Int8 (the constant materialisation and Bennett doubling account for the rest).

**FINDING 1 (Observation, no bug):** The carry wires are allocated but never
explicitly zeroed. In the forward computation they hold non-zero values. This
is fine because Bennett's construction will reverse these gates, returning the
carry wires to zero. However, the carry wires are *ancillae* of the adder
sub-circuit. This is correct by design --- Bennett handles them --- but it
means the adder is *not* independently reversible. It is a building block
that relies on the outer Bennett envelope. This is fine but should be stated.

### 1.2 Cuccaro In-Place Adder (`adder.jl`, lines 30--80)

The Cuccaro adder (arXiv:quant-ph/0410184) is more subtle. It uses MAJ
(majority) and UMA (unmajority-and-add) gates to compute a+b in-place,
overwriting b with the sum and using only 1 ancilla.

**Phase 1 (MAJ ripple up):**

First MAJ on (X[1], b[1], a[1]):
```
b[1] ^= a[1]       -- CNOT(a[1], b[1])
X[1] ^= a[1]       -- CNOT(a[1], X[1])
a[1] ^= X[1] & b[1] -- Toffoli(X[1], b[1], a[1])
```

After this: b[1] = b_1 XOR a_1, X[1] = a_1, a[1] = a_1 XOR (a_1 & (b_1 XOR a_1)).

Wait. Let me be more careful. Initially X[1] = 0, b[1] = b_1, a[1] = a_1.

Step 1: b[1] = b_1 XOR a_1.
Step 2: X[1] = 0 XOR a_1 = a_1.
Step 3: a[1] = a_1 XOR (a_1 AND (b_1 XOR a_1)).

Now a_1 AND (b_1 XOR a_1) = a_1 b_1 XOR a_1. So a[1] = a_1 XOR a_1 b_1 XOR a_1 = a_1 b_1.
But the carry should be MAJ(0, b_1, a_1) = (0 AND b_1) XOR (0 AND a_1) XOR (b_1 AND a_1)
= b_1 AND a_1 = a_1 b_1. Wait, that's not right for MAJ.

Actually, MAJ(a, b, c) = (a AND b) OR (a AND c) OR (b AND c). The initial carry
c_0 = X[1] = 0. So MAJ(c_0, b_1, a_1) = MAJ(0, b_1, a_1) = a_1 AND b_1.
And indeed a[1] = a_1 b_1 = c_1. Correct.

**FINDING 2 (Bug, Severity: Medium):** In `lower_add_cuccaro!`, lines 61--62:

```julia
push!(gates, CNOTGate(a[W], b[W]))     # b[W] = b_W XOR a_W
push!(gates, CNOTGate(a[W-1], b[W]))   # b[W] = b_W XOR a_W XOR c_W = s_W
```

The comment says "s_W" but the sum of the MSB should be
s_W = a_W XOR b_W XOR c_{W-1} (the carry INTO position W, not c_W which is
the carry OUT of position W).

At this point in the algorithm, after the MAJ phase, a[W-1] holds c_{W-1}
(the carry into position W-1, which after the final middle MAJ for i = W-1
becomes c_W, the carry into position W). Wait --- let me reconsider.

Actually, for a W-bit mod-2^W addition, the comment on line 54 says
"a[W-1] now holds c_W (the overflow carry)." But after the middle MAJ loop
runs for i = 2 to W-1, the last iteration is i = W-1. The MAJ at position
i uses a[i-1] as the incoming carry. After MAJ at position W-1, a[W-1]
holds the carry c_W (carry out of position W-1, which is the carry into
position W). The MSB sum bit is s_W = a_W XOR b_W XOR c_W. But the loop
does NOT process position W (no MAJ for position W). So a[W-1] = c_W and
the code on lines 61--62 computes:

b[W] = b_W XOR a_W (line 61)
b[W] = b_W XOR a_W XOR c_W (line 62, since a[W-1] = c_W)

This gives b[W] = a_W XOR b_W XOR c_W = s_W. This IS the correct MSB sum.

On re-examination, the code is correct. The confusion arises because the
comment says "c_W" when it means the carry INTO position W (= carry out of
position W-1). In a W-bit adder with positions 1 through W, c_W is the carry
from position W-1 to position W. The code is right; the comment is slightly
misleading.

**Revised FINDING 2 (Observation, no bug):** The comment on line 54 should say
"a[W-1] now holds the carry into position W (c_{W}, the carry out of
position W-1)" rather than just "the overflow carry", which could be confused
with the carry out of position W (which is discarded in mod-2^W arithmetic).

### 1.3 Subtraction (`adder.jl`, lines 82--103)

Two's complement subtraction: a - b = a + (~b) + 1. The code:

1. Copies b to not_b, then NOTs each bit. Correct: not_b = ~b.
2. Sets carry[1] = 1 via NOT.
3. Runs the same ripple-carry as lower_add! but with (a, not_b) and carry[1]=1.

This correctly computes a + (~b + 1) = a - b (mod 2^W). Verified.

### 1.4 Shift-and-Add Multiplier (`multiplier.jl`, lines 1--28)

For each bit position i of b (1-indexed), computes the partial product
pp = a * b[i], shifted left by (i-1). Then accumulates via ripple-carry addition.

The partial product: for each bit k of a, `pp[k + shift] ^= a[k] & b[i]`
(Toffoli). This is correct: bit k of partial product i contributes to
position k + i - 1 of the result.

The `dest > result_width && break` on line 21 correctly discards partial
product bits that overflow the result width.

**Gate count**: W iterations, each with up to W Toffolis for partial product
and O(result_width) gates for addition. Total: O(W^2) Toffolis + O(W^2) for
additions. Consistent with the documented O(W^2) claim.

**FINDING 3 (Efficiency concern, Severity: Low):** Each iteration allocates a
fresh partial product array `pp` of `result_width` wires. For a W-bit multiply,
this totals W * result_width ancilla wires just for partial products. With
result_width = W, that's W^2 wires. The Cuccaro adder (1 ancilla per add)
would help, but `lower_mul_wide!` uses `lower_add!` (the non-in-place version),
not `lower_add_cuccaro!`. The in-place decision in `lower_binop!` only applies
to top-level `add` instructions, not to sub-calls from the multiplier. This is
a missed optimisation but not a correctness issue.

### 1.5 Karatsuba Multiplier (`multiplier.jl`, lines 36--113)

The Karatsuba identity: for a = a_hi * 2^h + a_lo and b = b_hi * 2^h + b_lo,

  a * b = z2 * 2^{2h} + z1 * 2^h + z0

where z0 = a_lo * b_lo, z2 = a_hi * b_hi, and
z1 = (a_lo + a_hi)(b_lo + b_hi) - z0 - z2.

The implementation computes cross sums a_lo + a_hi and b_lo + b_hi with one
extra bit (cross_w = hi_w + 1) to handle the carry. Correct.

**FINDING 4 (Potential bug, Severity: Medium):** Line 69:
```julia
cross_w = hi_w + 1  # max(h, hi_w) + 1 to avoid overflow
```

For odd W, h = W div 2 and hi_w = W - h. When W is odd, hi_w = h + 1 > h, so
cross_w = hi_w + 1 = h + 2. The a_lo has h bits and a_hi has hi_w = h+1 bits.
When adding h-bit a_lo to (h+1)-bit a_hi, the result can be at most h+2 bits.
So cross_w = hi_w + 1 = h + 2 is correct.

But on line 71: `for i in 1:h; push!(gates, CNOTGate(a_lo[i], a_cross[i])); end`
copies only h bits of a_lo into cross_w wires. The remaining cross_w - h = 2
bits of a_cross are left at zero. This is correct (zero-extension of a_lo).

Then on line 73--74:
```julia
for i in 1:hi_w; push!(gates, CNOTGate(a_hi[i], a_hi_pad[i])); end
a_sum = lower_add!(gates, wa, a_cross, a_hi_pad, cross_w)
```

a_hi has hi_w bits; a_hi_pad has cross_w = hi_w + 1 bits. This zero-extends
a_hi to cross_w bits. Correct.

The subtraction z1 = z1_full - z0 - z2 uses `lower_sub!` with operands extended
to prod_w = 2 * cross_w bits. The z0 extension (line 88) copies min(2*h, prod_w)
bits. For the z2 extension (line 92), min(2*hi_w, prod_w) bits are copied.
Since 2*hi_w <= 2*cross_w = prod_w, all bits are copied. Correct.

**FINDING 5 (Ancilla explosion, Severity: High for practical use):** The
Karatsuba implementation creates enormous numbers of ancilla wires. Each level
of recursion allocates fresh wires for cross sums, padded copies, extended
subtraction operands, shifted results, and addition accumulators. For a 64-bit
multiply, the recursion depth is about 4 levels (64 -> 32 -> 16 -> 8 -> base),
with 3 sub-multiplies per level. The total wire count grows roughly as
O(W^{log_2 3} * W) = O(W^{2.58}). This is *worse* in space than the schoolbook
multiplier (O(W^2) wires) while being better in gate count. The Bennett
construction then doubles these wires. For practical use, the Karatsuba path
should only be chosen when gate count (not space) is the primary concern.

### 1.6 Restoring Division (`divider.jl`)

The `soft_udiv` function uses the standard restoring division algorithm:

```
for i in 63 down to 0:
    r = (r << 1) | bit i of a
    if r >= b: r -= b; set quotient bit i
```

This is textbook. The branchless version uses `ifelse` for the conditional
subtraction. For 64 iterations on a 64-bit value, the algorithm is correct.

**FINDING 6 (Observation):** The `soft_urem` function duplicates the loop
body of `soft_udiv`, returning r instead of q. This is correct but wasteful
in code --- a combined divmod could return both. More importantly, when used
as a gate-level callee (via `register_callee!`), the full 64-iteration loop
is compiled to reversible gates. Each iteration involves a 64-bit comparison
and conditional subtraction, so the gate count is O(64 * 64) = O(4096) basic
operations, each expanding to O(64) gates, giving roughly O(262,144) gates
for a single 64-bit division. This is enormous but inherent to the algorithm.

---

## 2. Bennett Construction Verification

### 2.1 The Core Construction (`bennett.jl`)

The `bennett` function is remarkably simple:

```julia
function bennett(lr::LoweringResult)
    # ... setup ...
    append!(all_gates, lr.gates)           # Forward
    for (i, w) in enumerate(lr.output_wires)
        push!(all_gates, CNOTGate(w, copy_wires[i]))  # Copy
    end
    append!(all_gates, reverse(lr.gates))  # Reverse
    # ...
end
```

**Correctness argument:** Let the forward gates transform the state
|x, 0...0> to |x, g_1(x), g_2(x), ..., g_m(x), f(x)>
where g_i are intermediate values and f(x) is the output. The CNOT copy
step maps this to
|x, g_1(x), ..., g_m(x), f(x), f(x)>
(the copy wires now hold f(x)). Reversing the forward gates undoes the
computation:
|x, 0, ..., 0, f(x)>.

This is correct IF AND ONLY IF:

(a) Every gate is self-inverse (NOT, CNOT, Toffoli are all involutions). True.

(b) The forward gates treat input wires as read-only (control only, never target).
This is an implicit invariant of the lowering. **If any gate targets an input
wire, the reverse pass will not restore it correctly.** The lowering must ensure
this.

(c) The copy wires are fresh (initialized to zero) so the CNOT truly copies.
True by construction (allocated at `lr.n_wires + 1`).

**FINDING 7 (Critical invariant, Severity: High if violated):** The correctness
of Bennett's construction depends entirely on the invariant that input wires
are never targeted by any gate in `lr.gates`. I searched the lowering code and
found that `lower_add_cuccaro!` OVERWRITES `b` wires (line 79: `return b`).
When the Cuccaro adder is used for `a + b`, the `b` operand's wires are
modified in place. If `b` is an SSA variable that is referenced later, its
wires now hold a+b rather than b. The liveness check in `lower_binop!`
(line 898--899) guards this:

```julia
op2_dead = inst.op2.kind == :const ||
           (inst.op2.kind == :ssa && get(ssa_liveness, inst.op2.name, 0) <= inst_idx)
```

This means the Cuccaro adder is only used when op2 is dead after this
instruction. Critically, the `b` wires here are never *input wires of the
function* (those are never SSA-dead at any point since they could be used by
the Bennett reverse pass). Actually, wait --- the input wires are the original
argument wires. The `b` wires passed to the adder are the resolved wires of
`inst.op2`, which for an SSA variable are allocated wires (possibly copies of
inputs). They are NOT the raw input wires. So this is safe.

**However:** If the liveness analysis has a bug (off-by-one, missing operand
tracking), the Cuccaro adder could corrupt a live value, leading to incorrect
uncomputation in the Bennett reverse pass. The ancilla-zero check in the
simulator would catch this. Still, this is a fragile invariant.

**FINDING 8 (Subtle correctness concern, Severity: Medium):** The
`lower_add_cuccaro!` function modifies `a` wires during the computation
(MAJ phase writes carries into `a[]` wires). The UMA phase restores them.
But if the computation is interrupted (e.g., by an error mid-way through),
the `a` wires are in an inconsistent state. More importantly: in the Bennett
reverse pass, these gates are replayed in reverse order. The reverse of the
Cuccaro adder is itself --- the MAJ+UMA structure is designed so that running
the gates backwards undoes the computation. This is correct because each
individual gate (CNOT, Toffoli) is self-inverse, and the sequence of gates
in the Cuccaro adder, when reversed, performs the inverse operation. No issue.

---

## 3. Pebble Game Analysis

### 3.1 Knill's Recursion (`pebbling.jl`, lines 22--49)

The dynamic programming table computes:

```
F(1, s) = 1                                        for s >= 1
F(n, 1) = Inf                                      for n >= 2
F(n, s) = min_{1 <= m <= n-1} [F(m,s) + F(m,s-1) + F(n-m,s-1)]  for n >= 2, s >= 2
```

**FINDING 9 (Bug, Severity: Medium):** The recurrence is WRONG. Knill's
Theorem 2.1 gives:

  F(n, s) = min_{1 <= m <= n-1} [F(m, s) + 2*F(n-m, s-1)]

The three terms in the code are F(m,s) + F(m,s-1) + F(n-m,s-1). The intended
semantics: forward the first m steps using s pebbles (cost F(m,s)), then
recursively process the remaining n-m steps using s-1 pebbles (cost F(n-m,s-1)),
then uncompute the first m steps using s-1 pebbles (cost F(m,s-1)).

Knill's original (arXiv:math/9508218, Theorem 2.1) states the recurrence as:

  T(n, k) = min_{m < n} [T(m, k) + 2*T(n-m, k-1)]

This is subtly different from the code. The key question: does uncomputing
m steps cost F(m, s-1) or F(m, s)? The answer depends on the pebbling model.
In Bennett's reversible pebbling game:

- Forward m steps: costs F(m, s) steps, uses s pebbles at peak.
- The checkpoint (step m) is now "frozen" --- it occupies 1 pebble.
- Process remaining n-m steps: costs F(n-m, s-1) (one pebble occupied by checkpoint).
- Uncompute first m steps: costs F(m, s-1) (still one pebble used by the
  checkpoint? No --- the checkpoint was consumed during the forward processing).

Actually, on closer reading of Knill 1995, the recurrence is:

  F(n, s) = min_{m} [F(m, s) + 2*F(n-m, s-1)]    (Eq. 2.1)

The "2*F(n-m, s-1)" comes from: (1) forward the remaining n-m steps, then
(2) unforward them, each using s-1 pebbles (the m-th checkpoint consumes one).

Wait, that doesn't match either. Let me re-derive. In the reversible pebbling
game for a chain of n nodes with s pebbles:

1. Pebble nodes 1..m using s pebbles: cost F(m, s).
2. Node m is now pebbled (1 pebble used). Recursively pebble nodes m+1..n
   using s-1 remaining pebbles: cost F(n-m, s-1). After this, node n is
   pebbled and nodes m+1..n-1 are unpebbled.
3. Unpebble nodes 1..m using s-1 remaining pebbles (node n holds 1): cost F(m, s-1).

Total: F(m, s) + F(n-m, s-1) + F(m, s-1).

This IS what the code computes! So the code matches Bennett's reversible
pebbling game. The formula in Knill's paper uses a slightly different model
(standard pebbling, not reversible). The code's recurrence is correct for
the *reversible* pebbling game.

**Revised FINDING 9 (No bug):** The recurrence F(m,s) + F(m,s-1) + F(n-m,s-1)
is the correct recurrence for the *reversible* pebbling game (where pebble
removal costs the same as placement). This matches the three-term recursion
described in the code comments. The min_pebbles function (line 58--61) returns
1 + ceil(log2(n)), consistent with the feasibility condition that F(n,s) < Inf
iff n <= 2^{s-1}.

**Verification:** F(1, s) = 1 for all s >= 1. Correct (pebble one node: 1 step).
F(2, 2): min over m=1: F(1,2) + F(1,1) + F(1,1) = 1 + 1 + 1 = 3. This means
pebbling 2 nodes with 2 pebbles takes 3 steps (forward 1, forward 1, unforward 1).
Correct.

### 3.2 Pebbled Bennett (`pebbling.jl`, lines 112--196)

The `pebbled_bennett` function applies the Knill recursion to the gate list.

**FINDING 10 (Bug, Severity: High):** In `_pebble_with_copy!` (lines 147--196),
the recursion does NOT correctly implement the Knill three-term recursion.

Lines 183--184: Step 1 "pebbles" the first m gates by simply running them forward:
```julia
for i in lo:mid
    push!(result, gates[i])
end
```

Lines 188--189: Step 2 recursively processes the remaining gates.

Lines 192--195: Step 3 "unpebbles" the first m gates by running them in reverse:
```julia
for i in mid:-1:lo
    push!(result, gates[i])
end
```

The problem: Step 1 should use F(m, s) steps, which may itself require recursive
sub-pebbling. But the code just runs the gates forward sequentially. This is
only correct when m <= s (the base case on lines 158--169: "Enough pebbles for
full Bennett on this segment"). When m > s, the forward pass of gates 1..m
requires recursive pebbling with s pebbles, but the code doesn't do this.

Similarly, Step 3 should use F(m, s-1) steps (recursive un-pebbling), but the
code just runs gates in reverse.

The net effect: the recursion computes the correct *split point* via
`knill_split_point`, but then applies the split using a flat forward/reverse
instead of recursive pebbling for the first m gates. This means the pebbled
construction uses more simultaneous wires than the pebble budget allows.

For the correctness of the *circuit* (ancillae return to zero): the flat
forward-reverse IS correct as a reversible operation. It's just not space-optimal.
The circuit will verify correctly in simulation, but it won't achieve the
space reduction promised by the Knill recursion.

This is a significant implementation gap between the cost computation
(`knill_pebble_cost`, which is correct) and the circuit generation
(`_pebble_with_copy!`, which ignores the recursive structure for the
forward/reverse phases).

---

## 4. Phi Resolution & Path Predicates

### 4.1 Path Predicate Computation (`lower.jl`, lines 640--711)

The path predicate system computes a 1-bit wire for each basic block, true
when execution reaches that block. The algorithm:

- Entry block: predicate = 1 (NOT gate on fresh wire).
- Conditional branch from B with condition c to T/F:
  - pred[T] = AND(pred[B], c)
  - pred[F] = AND(pred[B], NOT(c))
- Merge block: pred[M] = OR(pred[p1], pred[p2], ...).

**FINDING 11 (Correctness, no bug):** The predicates are mutually exclusive
within any single execution path, which is the key property needed for correct
MUX selection. If block B has predicate 1 and branches on c, then exactly one
of T (pred = c) and F (pred = NOT(c)) has predicate 1. The OR at merge points
sums these, and since they are mutually exclusive, the OR is equivalent to
addition mod 2. The predicates are exactly the Psi-SSA predicates from
Stoutchinin & Gao (CC 2004). Correct.

**FINDING 12 (Subtle concern, Severity: Low):** The `_or_wire!` function
(lines 648--656) computes OR(a, b) = a XOR b XOR (a AND b). This is correct
for Boolean values. However, it allocates a fresh wire for the result and
modifies it with three gates. These three wires and gates become ancillae in
the Bennett construction. For a block with k predecessors, the OR chain creates
k-1 intermediate OR wires. This is correct but generates O(k) ancilla wires
per merge point. For a function with many merge points (like the 12-way common.ret
in optimised LLVM IR), this is manageable.

### 4.2 Predicated Phi Resolution (`lower.jl`, lines 713--760)

The `resolve_phi_predicated!` function chains MUXes controlled by edge
predicates. For each incoming (value_i, block_i), it computes the edge
predicate (how execution reached the phi's block from block_i) and uses
it to select the corresponding value.

**FINDING 13 (Correctness concern, Severity: Medium):** The MUX chain
(lines 754--758) iterates from (length-1) down to 1:

```julia
result = incoming[end][1]
for i in (length(incoming) - 1):-1:1
    (wires, _) = incoming[i]
    result = lower_mux!(gates, wa, edge_preds[i], wires, result, W)
end
```

A MUX(cond, tv, fv) returns tv when cond=1, fv when cond=0. Here,
`lower_mux!(gates, wa, edge_preds[i], wires, result, W)` selects `wires`
(the true-value) when edge_preds[i] = 1, else `result` (the accumulated
false-value).

Since the edge predicates are mutually exclusive (exactly one is 1 for any
execution), this chain works: if edge_preds[k] = 1 for some k < length,
the MUX at iteration k selects `incoming[k]`, and all subsequent MUXes
(k-1, ..., 1) pass it through unchanged (their edge_preds are 0, so they
select the accumulated result). If k = length, no MUX fires and the initial
`result = incoming[end][1]` survives. Correct.

**FINDING 14 (Missing edge predicate for the last incoming value):** The
code computes edge predicates for ALL incoming values (loop on lines 732--751)
but uses edge_preds[i] only for i = 1..length-1. The last value
(incoming[end]) is used as the default. This works because the edge predicates
are mutually exclusive and exhaustive: if none of edge_preds[1..n-1] is 1,
then edge_preds[n] must be 1, and the default (incoming[end]) is the correct
value. However, edge_preds[end] is computed but never used, wasting gates for
the AND/NOT computation. Minor inefficiency.

### 4.3 Legacy Phi Resolution (`lower.jl`, lines 818--868)

The legacy `resolve_phi_muxes!` uses reachability-based partitioning. It tries
each branch to find one that cleanly splits the incoming values.

**FINDING 15 (Known bug, acknowledged):** The WORKLOG documents that this
algorithm fails for diamond CFGs where all values are reachable from both
sides of a branch (the "false-path sensitization" problem). The fix was to
implement path predicates (Section 4.1--4.2), which is now the primary
algorithm. The legacy code remains for backward compatibility but is
superseded. The code correctly falls through to path predicates when
`block_pred` is non-empty (line 769).

---

## 5. Loop Unrolling

### 5.1 Bounded Unrolling (`lower.jl`, lines 546--636)

The loop unrolling creates K copies of the loop body, using MUX-freeze to
preserve the state after the exit condition fires.

**FINDING 16 (Correctness, verified):** The MUX-freeze logic (lines 619--626):

```julia
# MUX(exit_cond, current, new_val): exit -> keep, continue -> update
vw[dest] = lower_mux!(gates, wa, exit_cond_wire, current, new_val, width)
```

When exit_cond = 1 (should stop), the MUX selects `current` (frozen value).
When exit_cond = 0 (should continue), the MUX selects `new_val` (latch value
from the next iteration).

This is correct: once the exit condition fires, all subsequent iterations see
exit_cond = 1 (because the body computes with frozen inputs, which re-derive
the same exit condition), so the MUX keeps selecting the frozen value.

**FINDING 17 (Edge case, Severity: Low):** If the loop body has side effects
on non-phi variables (i.e., computes values that are NOT loop-carried via phi),
those computations are wasted after the exit fires. This is fine for
correctness (the extra gates are undone by Bennett) but wastes gate count.
For the intended use (bounded loops in compiled LLVM IR), this is acceptable
since LLVM's phi nodes capture all loop-carried state.

**FINDING 18 (Off-by-one potential, Severity: Low):** The exit condition
negation (lines 608--611):

```julia
if !exit_on_true
    exit_cond_wire = lower_not1!(gates, wa, exit_cond_wire)
end
```

`exit_on_true` is computed on line 585: the exit is on the true side if the
true label is NOT the loop header (and not a latch). This logic assumes a
simple loop structure (header with conditional branch: continue or exit).
For complex loops with multiple exits or nested conditions, this could be
wrong. However, LLVM's loop simplify pass typically produces this simple form.

---

## 6. IEEE 754 Soft-Float Verification

### 6.1 soft_fadd (`softfloat/fadd.jl`)

This is the most complex single function in the codebase. Let me trace through
the critical paths.

**Unpacking (lines 25--31):** Standard IEEE 754 field extraction. Correct.

**Magnitude ordering (lines 52--61):** Swaps a and b so that |a| >= |b|. Uses
the absolute value (clear sign bit) for comparison. Correct.

**Implicit 1-bit (lines 64--65):** For normal numbers (exponent != 0), the
mantissa gets an explicit leading 1. For subnormals (exponent == 0), the raw
fraction is used (implicit 0). Correct.

**Effective exponents (lines 68--69):** Subnormals have stored exponent 0 but
effective exponent 1. This is the standard IEEE 754 convention: E_eff = max(1, E_stored).
Correct.

**Working format (lines 73--74):** Left shift by 3 provides room for guard,
round, and sticky bits. After shift: bit 55 = implicit 1, bits 54--3 = fraction,
bits 2/1/0 = G/R/S. Correct.

**Alignment (lines 77--88):** The smaller operand wb is shifted right by d
(exponent difference), with sticky bit tracking.

**FINDING 19 (Potential precision issue, Severity: Low):** Line 81:
```julia
d_clamped = ifelse(d == UInt64(0), UInt64(1), ifelse(d >= UInt64(64), UInt64(63), d))
```

When d = 0, d_clamped = 1, and the lost_mask computation would indicate 1 bit
lost (the LSB). But d = 0 means no shift is needed. The code handles this on
line 86--88:
```julia
wb_aligned = ifelse(d >= UInt64(56), wb_large,
             ifelse(d > UInt64(0),   wb_mid,
                                     wb))
```

When d = 0, the third branch fires, selecting wb (unshifted). So the d_clamped
= 1 computation of wb_mid is a dead value. No precision loss. The clamping is
just to avoid undefined behaviour in the shift operation. Correct.

**Addition and subtraction (lines 91--98):** Both wr_add and wr_sub are computed
unconditionally. The correct one is selected by `same_sign`. This is the
branchless approach that eliminates false-path sensitization. Correct.

**Normalisation --- overflow (lines 108--113):** If bit 56 is set (addition
carry), shift right by 1 and increment exponent. The sticky bit is preserved
by ORing the lost bit into position 0:
```julia
lost_ov = wr & UInt64(1)
wr_ov = (wr >> 1) | lost_ov
```

Correct. This preserves the sticky information.

**Normalisation --- underflow (lines 116--139):** Binary search CLZ in 6 stages
(32, 16, 8, 4, 2, 1). Each stage checks if the upper bits are all zero and
conditionally shifts.

**FINDING 20 (CLZ correctness, verified):** Let me trace for a value with
leading 1 at bit 45 (i.e., the value needs to shift left by 55 - 45 = 10).

Stage 1 (need32): bits [55:24] all zero? Bit 45 is in [55:24], so no. No shift.
Stage 2 (need16): bits [55:40] all zero? Bit 45 is in [55:40], so no. No shift.
Stage 3 (need8): bits [55:48] all zero? Bit 45 < 48, so yes. Shift left 8. Now
  bit 45 is at bit 53. Exponent decremented by 8.
Stage 4 (need4): bits [55:52] all zero? Bit 53 is in [55:52], so no. No shift.
Stage 5 (need2): bits [55:54] all zero? Bit 53 < 54, so yes. Shift left 2. Now
  bit 53 is at bit 55. Exponent decremented by 2.
Stage 6 (need1): bit 55 set? Yes (bit 55 = 1). No shift.

Total shift: 8 + 2 = 10. Exponent adjustment: -10. Correct.

**Rounding (lines 163--179):** Round-to-nearest-even (IEEE 754 default).

```julia
grs = (guard << 2) | (round_bit << 1) | sticky_bit
round_up = (grs > UInt64(4)) | ((grs == UInt64(4)) & ((frac & UInt64(1)) != UInt64(0)))
```

GRS encoding: guard is bit 2, round is bit 1, sticky is bit 0.
grs > 4 means guard=1 and (round=1 or sticky=1): round up. Correct.
grs == 4 means guard=1, round=0, sticky=0: tie, round to even (round up iff
frac is odd). Correct.

**FINDING 21 (Correctness, verified):** The rounding correctly implements
IEEE 754 round-to-nearest-even. The mantissa overflow check
(`frac_rounded == IMPLICIT`) catches the case where rounding 0xFFFFFFFFFFFFF + 1
= 0x10000000000000, which is 2^52 (the implicit bit position). In this case,
the fraction resets to 0 and the exponent increments. Correct.

**Final select chain (lines 189--200):** Priority order NaN > Inf > Zero >
exact_cancel > subnormal_flush > exp_overflow > normal. The `ifelse` chain
implements later entries overriding earlier ones (last write wins). So the
chain is evaluated bottom-to-top in priority:

Line 200: NaN → QNAN (highest priority)
Line 199: a_inf & !b_inf → a (Inf + finite = Inf)
Line 198: b_inf & !a_inf → b
Line 197: a_inf & b_inf → inf_inf_result (Inf + Inf = Inf or NaN)
Lines 195--196: zero + non-zero → non-zero (identity)
Line 194: both zero → signed zero
Line 193: exact cancellation → +0.0
Line 192: subnormal flush → signed zero
Line 191: exp overflow → ±Inf
Line 190: normal_result (lowest priority)

**FINDING 22 (Subtle correctness issue, Severity: Low):** Line 195:
```julia
result = ifelse(b_zero & (!a_zero), a, result)
```

When b is zero and a is not zero, the result should be a. But wait --- what
if a is NaN? Then a_nan would be true, and line 200 would override with QNAN.
Since the chain is bottom-to-top priority (later overrides earlier), and
line 200 comes after line 195, the NaN case is correctly handled. Similarly,
if a is Inf, line 199 would fire. The ordering is correct.

But there is a subtle issue: what if a is a subnormal? The input a is returned
as-is, which is correct (0 + subnormal = subnormal). What about -0.0 + 0.0?
Both a_zero and b_zero would be true (both have zero exponent and fraction),
so line 194 fires: `zero_zero_result = ifelse(sa == sb, a, UInt64(0))`. For
-0.0 + 0.0: sa = 1, sb = 0, sa != sb, so result = 0 (positive zero). This
matches IEEE 754: (-0) + (+0) = +0. Correct.

### 6.2 soft_fmul (`softfloat/fmul.jl`)

The mantissa multiplication uses a 53x53 -> 106 bit product via schoolbook
decomposition into four partial products of half-words.

**FINDING 23 (Correctness of 128-bit assembly, Severity: Medium):**
Lines 122--132 compute the 128-bit product:

```julia
acc_lo = pp_ll
term2 = cross << 26
sum1 = acc_lo + term2
c1 = ifelse(sum1 < acc_lo, UInt64(1), UInt64(0))
term3 = pp_hh << 52
sum2 = sum1 + term3
c2 = ifelse(sum2 < sum1, UInt64(1), UInt64(0))
prod_lo_final = sum2
prod_hi_final = (cross >> 38) + (pp_hh >> 12) + c1 + c2
```

Let me verify. The product P = pp_ll + cross * 2^26 + pp_hh * 2^52.

P mod 2^64 = pp_ll + (cross << 26) + (pp_hh << 52) (mod 2^64).
This is computed as sum2 = acc_lo + term2 + term3 with carry tracking. Correct.

P >> 64 = (cross >> 38) + (pp_hh >> 12) + carries.

Why cross >> 38? cross << 26 occupies bits [26, 26+54-1] = [26, 79].
The bits of (cross << 26) above bit 63 are cross >> (64-26) = cross >> 38. Correct.

Why pp_hh >> 12? pp_hh << 52 occupies bits [52, 52+54-1] = [52, 105].
The bits above 63 are pp_hh >> (64-52) = pp_hh >> 12. Correct.

The carry tracking (c1, c2) accounts for overflow in the lower 64 bits. Correct.

**FINDING 24 (Working format extraction, verified):** Lines 170--179 extract
56 bits from the 106-bit product for the working format. Two cases: MSB at
bit 105 (product >= 2^105) or MSB at bit 104.

For MSB at 105: extract bits [105:50] (56 bits), sticky from [49:0].
wr_105 = (prod_hi & ((1 << 42) - 1)) << 14) | (prod_lo >> 50)

prod_hi holds bits [64:105] = 42 bits. Bits [105:64] = prod_hi[41:0].
Bits [63:50] = prod_lo[63:50] = prod_lo >> 50 (14 bits).
Concatenation: (prod_hi[41:0] << 14) | (prod_lo >> 50). 42 + 14 = 56 bits. Correct.

### 6.3 soft_fdiv (`softfloat/fdiv.jl`)

The division uses restoring division to compute a 56-bit quotient from the
53-bit mantissas.

**FINDING 25 (Loop count, Severity: Medium):** Lines 49--56:
```julia
for i in 0:55
    fits = r >= mb
    r = ifelse(fits, r - mb, r)
    q = (q << 1) | ifelse(fits, UInt64(1), UInt64(0))
    r = r << 1
end
```

56 iterations (i = 0 to 55) produce 56 quotient bits. The initial remainder
r = ma (53 bits). After each iteration, r is shifted left by 1, so after 56
iterations, the quotient represents ma * 2^56 / mb (approximately). The
quotient has the leading 1 at bit 55 (if ma >= mb) or bit 54 (if ma < mb).

The normalisation on lines 64--66 handles the ma < mb case:
```julia
need_shift = (wr >> 55) == UInt64(0)
wr = ifelse(need_shift, wr << 1, wr)
result_exp = ifelse(need_shift, result_exp - Int64(1), result_exp)
```

This shifts the leading 1 to bit 55 and adjusts the exponent. But what about
the sticky bit? The `wr = q | sticky` on line 60 ORs the remainder-based
sticky into the quotient before normalisation. The additional left shift on
line 65 would shift the sticky bit up by 1, but since sticky is either 0 or 1
(in bit 0), after the shift it would be in bit 1. The original bits 2:0 of q
(the GRS bits of the quotient) would shift to bits 3:1, and bit 0 becomes 0.
This loses the sticky information.

**FINDING 26 (Bug, Severity: Low):** When `need_shift` is true (ma < mb),
the `wr << 1` on line 65 shifts the sticky bit from bit 0 to bit 1, and the
new bit 0 becomes 0. If the remainder was non-zero (sticky = 1), the sticky
information is now in bit 1 (the round bit position) rather than bit 0 (the
sticky position). This could cause an incorrect rounding decision in edge cases.

The correct fix would be to track sticky separately and re-inject it after
normalisation:
```julia
s = wr & UInt64(1)
wr = ifelse(need_shift, (wr << 1) | s, wr)
```

However, the error is only 1 ULP in edge cases where ma < mb AND the remainder
is non-zero AND the quotient's original bit 0 was 0 (otherwise the OR with
sticky was already 1). In practice, this may be masked by the 56 bits of
quotient precision exceeding the 53 bits needed. I would need to construct a
specific counterexample to confirm whether this actually causes a bit-inexact
result.

### 6.4 soft_fptosi (`softfloat/fptosi.jl`)

**FINDING 27 (Correctness, verified):** The conversion from double to int64
correctly handles the two cases: exponent >= 1075 (value >= 2^52, shift left)
and exponent < 1075 (value < 2^52, shift right to truncate fraction). The
sign handling via conditional two's complement negation is correct.

**FINDING 28 (Missing special case handling, Severity: Low):** The function
does not explicitly handle NaN or Inf inputs. For NaN: the mantissa has
arbitrary bits, and the exponent is 0x7FF. The left shift path fires
(exp = 2047 >= 1075), and `left_shift = 2047 - 1075 = 972`, clamped to 63.
The result is the mantissa shifted left by 63, which is undefined garbage.
This matches hardware behaviour (x86 `cvttsd2si` returns 0x8000000000000000
for NaN/Inf), but the comment on line 6 says "NaN/Inf -> undefined (match
hardware)". Acceptable for the stated goal.

### 6.5 soft_sitofp (`softfloat/sitofp.jl`)

**FINDING 29 (Bug, Severity: Medium):** The function handles the special
case of zero (line 17--18) and the absolute value computation (lines 22--23).
But there is a subtle issue with INT64_MIN (-2^63).

For INT64_MIN: a = 0x8000000000000000. sign = 1.
neg = (~0x8000000000000000) + 1 = 0x7FFFFFFFFFFFFFFF + 1 = 0x8000000000000000.
So magnitude = 0x8000000000000000, which is STILL negative in two's complement.

The CLZ of magnitude = 0x8000000000000000 is 0 (bit 63 is set). So:
exponent = 1086 - 0 = 1086.
shifted = magnitude << 0 = 0x8000000000000000.
mantissa = (shifted >> 11) & FRAC_MASK = 0.
round_bit = 0, sticky = 0, round_up = 0.
result = (1 << 63) | (1086 << 52) | 0 = sign bit set, exponent 1086, zero mantissa.

Exponent 1086 - 1023 = 63, so the value is -1 * 2^63 = -9223372036854775808.0.

In IEEE 754: Float64(-2^63) = -9.223372036854776e18. This is exactly representable
(2^63 is a power of 2, and the mantissa is 1.0 with exponent 63). The packed
result would be:
sign = 1, exponent = 1086 = 0x43E, mantissa = 0.
Bit pattern: 0xC3E0000000000000.

Let me verify: reinterpret(UInt64, Float64(-2^63)) = 0xC3E0000000000000.
exponent field: 0x43E = 1086. Mantissa: 0. Sign: 1. Value: -1 * 2^(1086-1023) = -2^63.

So the code produces the correct result for INT64_MIN despite the two's
complement overflow on the negation. This is because the magnitude
0x8000000000000000 has the leading 1 at bit 63, which is correctly detected by
the CLZ, and the mantissa is zero (all lower bits are zero). **No bug after all.**

---

## 7. Complexity Analysis

### 7.1 Gate Count Formulas

**Addition (W bits):** lower_add! uses 3W CNOT + 2(W-1) Toffoli per forward
pass. Bennett doubles this and adds W CNOT for the copy. Total:
6W CNOT + 4(W-1) Toffoli + W CNOT = 7W CNOT + 4(W-1) Toffoli.
But there is also the constant materialisation (for `x + 1`, the constant 1
requires NOT gates). The documented 86 gates for i8 x+1:
7*8 CNOT + 4*7 Toffoli + 2 NOT = 56 + 28 + 2 = 86. Exact match.

For wider types: the 2x scaling per width doubling (86, 174, 350, 702) is
NOT exactly 2x --- 86*2 = 172, not 174; 174*2 = 348, not 350; 350*2 = 700,
not 702. The discrepancy is 2 per doubling.

**FINDING 30 (Gate count discrepancy, Severity: Informational):** The documented
"exactly 2x per width doubling" is approximate, not exact. The actual scaling
is 86, 174, 350, 702. Differences: 174/86 = 2.023, 350/174 = 2.011,
702/350 = 2.006. The extra 2 gates per doubling come from the constant
materialisation: `x + 1` needs 1 NOT for the constant bit (i8: bit 0 only),
and for wider types the constant is still 1, requiring 1 NOT. But the Bennett
doubling of the NOT gates adds 1 more, giving 2 extra. Actually, for x + Int8(1),
the constant 1 requires NOTGate on bit 0 only (1 NOT). Bennett doubles all
gates, so 2 NOT total. For Int16: same 1 constant, same 2 NOT. The rest
scales exactly 2x: 7W CNOT + 4(W-1) Toffoli.

i8: 7*8 + 4*7 + 2 = 56 + 28 + 2 = 86.
i16: 7*16 + 4*15 + 2 = 112 + 60 + 2 = 174.
i32: 7*32 + 4*31 + 2 = 224 + 124 + 2 = 350.
i64: 7*64 + 4*63 + 2 = 448 + 252 + 2 = 702.

Exact formula: 11W - 2. This is O(W), as claimed.

**Multiplication (W bits):** lower_mul! iterates W times, each with W Toffolis
(partial product) and O(W) gates (addition). Total: O(W^2) Toffolis + O(W^2)
CNOT. The documented claim O(W^2) is correct.

### 7.2 Space Complexity

**Full Bennett:** 2|gates| + |output| gates, |input| + |ancilla| + |output| wires.
The ancillae include all wires allocated during lowering minus the input wires.
For W-bit addition: 2W (result) + 2W (carry) + W (copy) + W (input) = 6W wires
total. O(W), consistent.

---

## 8. Invariant Maintenance

The system maintains several critical invariants. Let me enumerate them and
assess their enforcement.

**Invariant 1: Input wires are never targets.**
Enforcement: The lowering functions (lower_add!, lower_sub!, etc.) allocate
fresh wires for all results. Input wires are only used as controls (CNOT/Toffoli).
Exception: `lower_add_cuccaro!` modifies `a[]` wires during computation but
restores them. The `b[]` wires are overwritten (this IS the result). The liveness
check ensures `b` is dead. Enforcement: *partial* (relies on liveness analysis).

**Invariant 2: All ancillae return to zero after Bennett construction.**
Enforcement: The simulator (line 30--31) asserts this for every simulation.
The `verify_reversibility` function (diagnostics.jl, lines 127--143) checks
that running all gates forward then backward returns to the original state.
Enforcement: *strong* (tested empirically).

**Invariant 3: Each gate is self-inverse.**
Enforcement: By definition of NOT, CNOT, Toffoli. Trivially maintained.

**Invariant 4: Wire allocator never reuses a wire that is not zero.**
Enforcement: The `free!` function's docstring says "Wires MUST be in zero state"
but there is no runtime check. Enforcement: *weak* (documentation only).

**FINDING 31 (Missing invariant check, Severity: Medium):** The `free!` function
in `wire_allocator.jl` does not verify that the freed wires are actually zero.
In debug mode, it should assert this. A wire freed while non-zero would corrupt
subsequent computations that allocate it, leading to silent errors that the
ancilla-zero check might not catch (because the reused wire is not classified
as an ancilla of the outer computation).

**Invariant 5: Constant folding preserves semantics.**
The `_fold_constants` function (lower.jl, lines 323--416) propagates known
values and eliminates redundant gates. At the end (lines 407--411), it
materialises remaining non-zero known values as NOT gates.

**FINDING 32 (Correctness of constant folding, Severity: Medium):** The
constant folding handles NOTGate by toggling the known value (line 336), and
never emits the gate. This means the constant value is tracked in the `known`
dictionary but not in the gate list. When a CNOT or Toffoli with a known
control operates on an unknown target, the known value is "consumed" by the
interaction. The code correctly handles this (lines 341--401). However:

Line 384: When a Toffoli has one known-true control, it reduces to a CNOT.
Before emitting the CNOT, it materialises the target's known value if needed:
```julia
if t_known
    if known[gate.target]; push!(folded, NOTGate(gate.target)); end
    delete!(known, gate.target)
end
push!(folded, CNOTGate(gate.control2, gate.target))
```

This is correct: the materialisation ensures the wire is in the correct state
before the data-dependent CNOT operates on it.

But what about the ORDER of materialisation at the end (lines 407--411)?
```julia
for (w, v) in known
    if v
        push!(folded, NOTGate(w))
    end
end
```

Dictionary iteration order in Julia is not deterministic. If the final
materialisation order matters (e.g., if two known wires interact in subsequent
gates), this could be wrong. However, since these materialisations are at the
END of the gate list (after all data-dependent gates), and each materialisation
is independent (NOTGate on distinct wires), the order doesn't matter. Correct.

---

## 9. Specific Findings (Summary)

| # | Severity | File | Line(s) | Description |
|---|----------|------|---------|-------------|
| 1 | Info | adder.jl | 1--16 | Adder is not independently reversible; relies on outer Bennett. By design. |
| 2 | Info | adder.jl | 54 | Comment "overflow carry" is ambiguous; means carry into MSB position. |
| 3 | Low | multiplier.jl | 24 | Multiplier uses lower_add! not lower_add_cuccaro!, missing optimisation. |
| 4 | Low | multiplier.jl | 69 | Karatsuba cross_w computation correct but comment misleading. |
| 5 | High | multiplier.jl | 36--113 | Karatsuba has O(W^2.58) wire count, worse than schoolbook. Document tradeoff. |
| 7 | High | adder.jl + lower.jl | 79, 898 | Cuccaro in-place adder safety depends on liveness analysis correctness. |
| 10 | **High** | pebbling.jl | 183--195 | `_pebble_with_copy!` does not recursively pebble the first m gates; uses flat forward/reverse instead of recursive sub-pebbling. Space budget not honoured. |
| 12 | Low | lower.jl | 648--656 | OR gate for merge predicates generates O(k) ancilla wires per merge point. |
| 13 | Medium | lower.jl | 754--758 | Predicated phi MUX chain correct but relies on mutual exclusivity of predicates. |
| 14 | Low | lower.jl | 732--751 | Edge predicate for last incoming value computed but unused. Wasted gates. |
| 22 | Low | softfloat/fadd.jl | 195 | Zero + non-zero select ordering relies on later overrides for NaN. Correct but fragile. |
| 26 | Low | softfloat/fdiv.jl | 64--66 | Normalisation shift may misplace sticky bit. Possible 1-ULP error in edge cases. |
| 30 | Info | WORKLOG.md | -- | "Exactly 2x" scaling is approximate. Exact formula: 11W - 2. |
| 31 | Medium | wire_allocator.jl | 23--29 | `free!` does not verify wires are zero. Silent corruption risk. |
| 32 | Medium | lower.jl | 323--416 | Constant folding correct but relies on materialisation order independence. |

---

## 10. Recommendations

### 10.1 Fix the Pebbled Bennett Implementation (Finding 10)

This is the most significant bug. The `_pebble_with_copy!` function must
recursively apply the Knill strategy to Steps 1 and 3, not use flat
forward/reverse. The fix is conceptually straightforward: replace the flat
loops with recursive calls. Something like:

```julia
# Step 1: Pebble first m gates with s pebbles
_pebble_with_copy!(result, gates, empty_copy, lo, mid, s, false)
# Step 2: Recursively process remaining gates with s-1 pebbles
_pebble_with_copy!(result, gates, copy_gates, mid+1, hi, s-1, is_outermost)
# Step 3: Unpebble first m gates with s-1 pebbles
_pebble_with_copy!(result, gates, empty_copy, lo, mid, s-1, false)
```

But note: "pebbling" in Steps 1 and 3 means the gates must end in a state
where they are "applied" (for Step 1) or "unapplied" (for Step 3). A simple
Bennett envelope (forward + reverse) leaves the state unchanged --- that's the
wrong thing. You need the forward pass to leave the intermediate state LIVE
(not cleaned up) so that the checkpoint at position m exists. This requires
a different primitive: "forward without cleanup" for Step 1, and "cleanup
without forward" for Step 3.

The current base case (lines 158--169) does forward + copy + reverse, which
is a full Bennett. For Step 1, you need only the forward part. For Step 3,
you need only the reverse part. The recursion must distinguish these modes.

I recommend reading Li and Vitanyi, "Reversible simulation of irreversible
computation by pebble games" (Theoretical Computer Science, 2000) for a
clean exposition of the recursive structure.

### 10.2 Add Debug Assertions to Wire Allocator

The `free!` function should, in debug mode, accept a bit vector and verify
that the freed wires are zero. This would catch the silent corruption that
Finding 31 describes.

### 10.3 Clarify Cuccaro Adder Comments

The comments in `lower_add_cuccaro!` should explicitly state which wire holds
which value at each phase transition. The Cuccaro paper's Figure 5 has a
clear state table; the code should replicate it.

### 10.4 Document Karatsuba Space Tradeoff

The Karatsuba multiplier should come with a clear warning that it uses more
wires than the schoolbook multiplier. The `use_karatsuba` flag should document
when it is advantageous (gate count reduction) versus disadvantageous (space
increase).

### 10.5 Guard Against Liveness Analysis Bugs

The Cuccaro in-place adder's correctness depends on the liveness analysis being
correct. Add a defensive check: after the Cuccaro adder, verify (in debug mode)
that the overwritten `b` wires are not referenced by any subsequent instruction
in the same basic block.

### 10.6 Soft-Float fdiv Sticky Bit

The normalisation shift in `soft_fdiv` (Finding 26) should preserve the sticky
bit. The fix is one line:
```julia
s = wr & UInt64(1)
wr = ifelse(need_shift, (wr << 1) | s, wr)
```

### 10.7 Code Organisation

The `lower.jl` file at 1421 lines is too large for comfortable review. The
phi resolution algorithm (200+ lines), loop unrolling (90+ lines), comparison
operations (70+ lines), and shift operations (80+ lines) should each be in
their own file. This would make it easier to verify each component independently.

---

## Closing Remarks

Bennett.jl is an ambitious project that tackles a genuinely novel compilation
problem. The core insight --- operating at the LLVM IR level to reversibilise
arbitrary programs, in the same spirit as Enzyme for automatic differentiation
--- is sound and, to my knowledge, unprecedented in the literature.

The basic building blocks (ripple-carry adder, subtraction, schoolbook
multiplier, restoring divider) are correct. The Bennett construction itself is
correct and minimal. The branchless soft-float implementations are impressive
in their completeness (handling all five IEEE 754 special cases) and their
verified bit-exactness.

The most significant issues are:

1. The pebbled Bennett construction does not implement the recursive structure
   it claims (Finding 10). This is a gap between the mathematical model
   (which is correct) and the implementation (which is flat).

2. The in-place Cuccaro adder's safety relies on a liveness analysis that, if
   it has an off-by-one error, would lead to silent corruption of the Bennett
   invariant (Finding 7). The simulator's ancilla-zero check would catch this,
   but only for the specific inputs tested.

3. The Karatsuba multiplier's space complexity is worse than the schoolbook
   alternative (Finding 5), which should be documented.

The path-predicate phi resolution (Section 4.1--4.2) is the right approach
for arbitrary CFGs and appears to be correctly implemented. The legacy
reachability-based resolver should be removed or clearly marked as deprecated.

The project's testing discipline --- exhaustive verification over all inputs
for Int8 functions, random testing for wider types, and mandatory
ancilla-zero assertions --- provides strong empirical evidence of correctness.
For a system of this complexity, where formal verification would require
formalising LLVM IR semantics, this level of testing is appropriate.

I would award this project a grade of **B+**. The algorithms are mostly correct,
the testing is thorough, and the ambition is commendable. The pebbling
implementation gap and the code organisation prevent a higher grade. Fix
Finding 10, add the defensive checks I recommend, and this becomes an A.

--- Donald E. Knuth, April 2026
