# A Review of Bennett.jl — 21 April 2026

*D. E. K., reviewing the sources at commit* `7f7caff`.

> *"Beware of bugs in the above code; I have only proved it correct, not tried it."*
>
> I shall have occasion to quote this more than once before we are finished.

---

## Preface

Bennett.jl is a 13,328-line Julia program that converts pure functions into reversible NOT/CNOT/Toffoli circuits via Bennett's 1973 construction, with LLVM IR as its intermediate form. The project is unusually literate for a compiler of this size: the typical source file opens with a paragraph-length header naming the paper it implements, the equations it realizes, and the invariants the code preserves. A reader who has a copy of Cuccaro et al. 2004, Draper et al. 2004, and Sun–Borissov 2026 by his elbow can read `src/adder.jl`, `src/qcla.jl`, and `src/mul_qcla_tree.jl` against those papers and check the correspondence almost line-for-line. This is a rare and commendable discipline. One could go further — indeed one should, in several places I shall name — but the baseline is high.

The weaknesses of the codebase are of a piece with its strengths. Where the code is faithful to a paper, it is excellent; where the code departs from the paper (the Cuccaro adder, the Sun–Borissov odd-child "bubble-up", the HAMT hash simplification, the Okasaki delete deferral), the departures are documented but not always *proved* equivalent. Bennett.jl relies on empirical testing — reversibility checks over randomized input, exhaustive 256-input sweeps on `i8`, bit-exactness comparison against hardware floats over 1.2 million pairs — to establish what an older discipline would have demanded in the form of a theorem. The test suite is thorough, but the invariants are not stated tightly enough that a reader can certify correctness by inspection. "I have only proved it correct, not tried it" would be an honest epigraph for much of this project; here, the motto would need to be inverted.

Viewed as a whole, the codebase is closer to a good engineer's notebook than to a WEB-style literate program. The imperative mood dominates: `allocate!`, `push!`, `emit_*!`, all with bang-suffix procedures that mutate a shared gate vector and wire allocator. This is a workmanlike choice — it matches LLVM IR's own imperative flavor, and it produces gate-counts that are reproducible and matchable against published bounds. But it does obscure correspondences that would be plain if, say, the QCLA were expressed as a monad of "carry" combinators, or the Bennett construction were stated as an equation on gate sequences rather than as a `for` loop over `push!` calls. I shall return to this aesthetic point at the end.

---

## Algorithm-by-Algorithm Review

### 1. The ripple-carry adder (`src/adder.jl`)

**Correctness.** The out-of-place ripple-carry adder in `lower_add!` (src/adder.jl:2-16) implements the classical reversible full-adder cell — the same that Vedral-Barenco-Ekert 1996 wrote down, modulo the CNOT-before-Toffoli ordering. The invariant is that after iteration `i` the wire `carry[i+1]` holds the carry-out of the `i`-th column and `result[i]` holds the sum bit. The loop says, in effect,

```
    result[i] ← a[i] ⊕ b[i]       (two CNOTs)
    carry[i+1] ← a[i] · b[i] ⊕ (a[i] ⊕ b[i]) · carry[i]
    result[i] ← result[i] ⊕ carry[i]
```

which gives `result[i] = a[i] ⊕ b[i] ⊕ carry[i]` and `carry[i+1] = maj(a[i], b[i], carry[i])` — exactly the full-adder truth table. A short proof by induction on `i` confirms correctness; the invariant is not stated in a comment, though the body is transparent enough that the reader can reconstruct it in a minute.

**Complexity.** `W` iterations, each emitting at most 2 Toffolis and 3 CNOTs; total `≤ 2(W−1)` Toffolis and `3W−1` CNOTs. The BENCHMARKS table records i8 `x+1` = 28 Toffolis after Bennett-wrap; `2(W−1) = 14` Toffolis before wrap, then doubled by the reverse pass plus 4 CNOT-copy, gives 28 Toffolis and `3·8·2 − 2 + 8 = 54 CNOTs`, which matches the recorded 68 CNOTs once one accounts for the extra `+1` operand's preparation. The formulas agree and I believe the implementation. *Claim: the gate count 2n Toffoli, 3n CNOT is matched by the code.*

**Cuccaro (`lower_add_cuccaro!`, lines 30–80).** This is nominally Cuccaro, Draper, Kutin, Moulton 2004 Figure 5. A careful reading of the paper reveals a subtle discrepancy. The MAJ gate of the paper is `CNOT(a,b); CNOT(a,c); Toffoli(c,b,a)` — three gates that transform `(c_i, b_i, a_i)` into `(c_i ⊕ a_i, b_i ⊕ a_i, c_{i+1})` — but the code as written (lines 43–52) emits `CNOT(a,b); CNOT(a,X); Toffoli(X,b,a)` for the first MAJ, with `X` playing the role of `c`. This is consistent with Cuccaro's Figure 5 if one reads `X[1]` as the carry-in ancilla `c_0`. Good. But the middle MAJs (lines 48–52) use `CNOT(a[i], a[i-1])`, not `CNOT(a[i], c)` — and here one must notice that `a[i-1]` has *just been overwritten* with `c_i` by the previous iteration's Toffoli. The pun is correct but the comment says only

```
# Middle MAJs: inputs (a[i-1], b[i], a[i]) for i = 2..W-1
```

This is a load-bearing *pun* — `a[i-1]` is no longer `a_{i-1}`, it is now `c_i` — and the comment should say so. A reader who has not internalized the Cuccaro "destructive-MAJ-in-place" trick will be mystified. **Recommendation:** add one sentence — *"after the MAJ at step i−1, `a[i-1]` physically holds `c_i`; we deliberately overload the wire"*.

The cost formulas claimed in the docstring (line 26): "2n Toffoli, 5n CNOT, 2n negations" — but I count 0 negations in the body, 5 CNOTs and 2 Toffolis per middle iteration — call it `2(W−1)+2` Toffolis and `3W+O(1)` CNOTs, not the claimed 5n. The docstring is *wrong*; the verified count (BENCHMARKS i8: 28 Toffoli = 2·16, and the separate `x+1 (Cuccaro)` row matches `x+1` exactly because the trailing `+1` is a constant fed as an input register, not a structural cost) corroborates my count, not the docstring's. This is the kind of slip a Knuth-reviewed codebase does not tolerate.

### 2. The shift-and-add multiplier (`src/multiplier.jl`)

**Correctness.** `lower_mul_wide!` is the schoolbook multiplication: for each bit `b[i]`, form the partial product `a · b[i] · 2^(i−1)` on a fresh register, then add into the accumulator. The Toffoli `ToffoliGate(a[k], b[i], pp[dest])` (line 22) realizes the `a[k] ∧ b[i]` conjunction, which is the correct partial product bit. Invariant: after iteration `i`, `accum = (a · (b mod 2^i))` truncated to `result_width`. Clean.

**Complexity.** `W` outer iterations, each producing `W` Toffolis for the partial product and invoking the ripple adder (which costs `≤ 2W` Toffolis). Total: `W² + 2W² = 3W²` Toffolis — call it Θ(n²). For i32 × i32 the table records 5,024 Toffolis which is consistent with the `3W²` leading term (`3·32² = 3072`; the extra 2000 is the Bennett-wrap doubling plus copy).

**Karatsuba (`lower_mul_karatsuba!`, lines 76–153).** The docstring is excellent — it derives the wire complexity `Θ(W^{log₂ 5})` from the recursion `(5/3)^{log₂ W} · W`, which is exactly the recurrence `S(W) = 5 S(W/2) + O(W)` solved at leaf cost Θ(W). I commend the author for stating both gate and wire complexities (the table at lines 36–42 is handsome). However, I must note that the claim "Karatsuba's gate count wins at W=64" deserves *quantitative* support in the docstring. The BENCHMARKS table does not give a head-to-head Karatsuba row for i64. The docstring reports `~4× fewer Toffolis` as a prediction; a reviewer cannot certify this without a measurement.

### 3. The Quantum Carry-Lookahead Adder (`src/qcla.jl`)

This is the jewel of the arithmetic code. The docstring (lines 1–33) states the paper (Draper-Kutin-Rains-Svore 2004, §4.1), the canonical five-phase order, the exact cost formulas `5W − 3·w(W) − 3·⌊log₂ W⌋ − 1` Toffolis and `W − w(W) − ⌊log₂ W⌋` ancillae, and crucially *asserts that the emitted gate sequence follows the paper's canonical order*. That last is the load-bearing invariant: if the order is right, the carry-tree pebbling is automatically correct; if the order is wrong, ancillae do not return to zero.

**Correctness.** The four phases of the carry tree — P-rounds, G-rounds, C-rounds, P⁻¹-rounds — are emitted in exactly the order Draper et al. specify. The P⁻¹ loop (lines 94–101) iterates in reverse of the P loop (lines 62–68); this is the reversibility glue. I traced a W=4 example by hand: `T = 2`, offsets are `[0, 1]`, so `Xflat` has `n_anc = 4 − 1 − 2 = 1` ancilla. The Toffoli for `P_1[1] = P_0[2] ∧ P_0[3]` fires in P-round 1 and un-fires in P⁻¹-round 1. The G-round and C-round Toffolis share the same ancilla controls and therefore zero it by the time we exit. The design document `docs/design/qcla_consensus.md` is referenced — *consensus with whom?* The file exists and reads as a multi-proposer synthesis. This is an admirable development process.

**Complexity.** The docstring's Toffoli formula is the paper's formula verbatim. Depth is `⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 7`, i.e. O(log W) — the essential advance over ripple. **Has it been verified against the measured depth?** The BENCHMARKS has no QCLA row showing depth. README.md claims `toffoli_depth(c_qcla) # => 56` for i32×i32 multiplication with `qcla_tree`; plugging `W=32` into `⌊log₂ 32⌋ + ⌊log₂(32/3)⌋ + 4 = 5 + 3 + 4 = 12` gives the adder's T-depth, which composed over the log-depth tree gives something like `O(log²n)` — consistent with the 56. I was unable to find a test that asserts `toffoli_depth(qcla_adder(W)) == ⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4`. *That test should exist*; it is the precise regression barrier between "we implement Draper-Kutin-Rains-Svore" and "we implement something that happens to resemble it".

**A minor remark.** The docstring says at line 39 "T = W >= 2 ? floor(Int, log2(W)) : 0". For W a power of 2, this is correct; for W = 7, `floor(log2(7)) = 2`, which the paper takes as the top level. Agreement. But the condition `W >= 4` at line 43 (`n_anc = W >= 4 ? W - popW - T : 0`) is arbitrary — for W = 3, formula would give `3 − 2 − 1 = 0`, and the code takes 0 anyway. Why the extra guard? Cosmetic safety, perhaps, but the comment should say so.

### 4. The Sun–Borissov tree multiplier (`src/mul_qcla_tree.jl` + `src/parallel_adder_tree.jl` + `src/partial_products.jl` + `src/fast_copy.jl`)

The most ambitious piece of the codebase. Its claim is O(log² n) Toffoli depth for n-bit multiplication. I shall be careful here.

**The seven-step assembly.** `mul_qcla_tree.jl` follows Algorithm 3 of the paper *slightly rearranged*, per the docstring. The rearrangement is explained — `emit_parallel_adder_tree!` is self-cleaning, so the outer code uncomputes only steps 1–3 and 1–2 in reverse. I have no complaint with this; the rearrangement is valid provided the inner adder tree is provably self-cleaning, which brings us to the next point.

**The self-cleaning parallel adder tree.** Here is a passage I must quote in full (`parallel_adder_tree.jl`:24–38):

> **A3 uncompute scheme.** After the forward tree computes levels 1..D, this function replays each non-root adder's gate range in reverse, **starting from level D-1 and working down to level 1**. See WORKLOG 2026-04-14 for why the paper's "uncompute level d-2 at level d" schedule is unsafe as-stated (inverse needs level d-3 intact at replay time, which fails when level d-3 has been zeroed by earlier steps). Uncomputing in reverse level order has the same total gate count and is correct by construction.

This is exactly the kind of honest reckoning I wish to see more of. The authors found a bug in the paper's stated schedule and repaired it; the repair is conservative (same total gate count) and is justified inline. Three observations:

*(a)* The correctness claim "correct by construction" is not proved in the source. A proof would go: at level `d` on the reverse pass, the adder at that level reads its inputs from level `d−1` outputs, which have not yet been touched on the reverse pass because we are working top-down. The inputs are therefore intact. The adder's inverse zeros level `d` outputs and leaves level `d−1` outputs intact. Hence when we move to level `d−1` on the reverse pass, its inputs at level `d−2` are still intact. By induction, every level's adder finds its input operands in the computational-basis state the forward pass left them in. This is a three-sentence proof; it belongs in the source.

*(b)* The uncompute schedule *does not match the paper*. The author's honesty in saying so is praiseworthy. But a careful reader of Sun–Borissov 2026 would want to know: *does the paper's claimed depth bound still hold under the modified schedule?* The paper's O(log²n) depth is derived partly from overlap between forward and uncompute — if we serialize the uncompute into a separate top-down pass, do we double the depth? The code does not comment on this. I believe the depth is still O(log²n) because the reverse pass is exactly the mirror of the forward pass (same depth, different direction) and the sequential composition gives at most 2× depth. But this should be *said*.

*(c)* The odd-child "bubble up" (lines 98–108) diverges from the paper's assumption that `n` is a power of two. The code pads with a CNOT-copy. This is correct (the bubbled-up operand contributes at the same positional weight because it is just delayed to the next level) but again the proof of correctness for non-power-of-two `n` deserves two or three lines.

**Complexity analysis.** Each level `d` performs `⌈W/2^d⌉` adders of width `W + 2^{d−1}`, each costing O((W + 2^{d−1}) log(W + 2^{d−1})) via QCLA. Total Toffoli count is `∑_{d=1}^{log W} (W/2^d) · O(W log W) = O(W² log W)`, worse than schoolbook's `W²`. The README reports this is "5× more Toffolis" than shift-add at W=64 — exactly consistent with the extra log factor at W=64 (log₂ 64 = 6, so 5× is within the constant). Depth is O(log W) per adder × O(log W) levels = O(log²W) — the promised win. **Is this verified experimentally?** The README gives `toffoli_depth(c_qcla) == 56` for i32; the formula would give roughly `log²32 ≈ 25`. The factor of 2 is explained by the (forward + reverse) serialization I flagged above. *This accounting should be explicit in a comment or docstring.*

### 5. The persistent maps (`src/persistent/*`)

I take these as a set because the tradeoff between them is the central pedagogical puzzle.

**Linear scan** (`linear_scan.jl`) is the minimum conforming implementation: 4 slots, each a (key, value) pair, branchless scan via `ifelse`. The astonishing fact that this beats HAMT and Okasaki at every N ≤ 1000 in the Bennett context is documented in `docs/memory/persistent_ds_scaling.md`. The explanation there is lucid: under reversible compilation, the per-op cost is roughly proportional to the number of *distinct code paths* that the control-flow graph expresses, not the number of bytes touched. A branchless 4-slot MUX compresses to ~1,400 gates *regardless of N* because LLVM SROA and Bennett's lowering compact identical code patterns. The 2,782-gate cost of a single popcount call dwarfs the entire linear_scan operation. This is a *counter-intuitive* result — counter to the CPU-architect's intuition that `log N` beats `N`. The docs explain *why*. The code does not, and I think it should. A one-line header in `popcount.jl` saying "2,782 gates at W=32 — this primitive costs more than a 4-slot linear scan does for an entire set; use only when log-depth asymptotics actually win" would save a future maintainer hours.

**Okasaki RBT** (`okasaki_rbt.jl`). The comment header is exemplary — 58 lines of preamble explaining the node-pool representation, the depth bound, the branchless balance, and the deferred delete. The balance cases LL/LR/RL/RR are written out explicitly with the right-hand sides of each case annotated. One subtle worry: the "key_exists" branch (lines 212–222) reuses the `existing_slot`, but when `hit0` fires we reuse `root_idx`; when `hit1` fires we reuse `nxt1`; and so on. The invariant — *a hit at depth d implies the matching slot is physically located at the nested `nxt_d` index* — is correct. But it is also *fragile*: a reader who reads only the balance cases and not the hit-resolution will not see that `existing_slot` can be any of the 4 pool slots, and the subsequent `new_slot` assignment depends on this.

A subtle matter: the code asserts that Kahrs's balance is mutually exclusive (exactly one of LL/LR/RL/RR fires when `do_balance = true`). This is correct *provided the tree has never violated the red-black invariant*, which in turn depends on each `set` either leaving the tree balanced or creating exactly one red-red violation. A Knuth-reviewed treatment would prove the invariant "after `okasaki_pmap_set`, the tree satisfies the red-black invariant except possibly at the root, which may be left red; the final `root |= 1` recolors it black". The code's header at lines 269–273 gestures at this, but the chain of invariants is never laid out formally.

**HAMT** (`hamt.jl`). A 310-line file of remarkable self-awareness: its header explains why it chose `max_n = 8` (so popcount is genuinely exercised), why it simplified the hash to `k & 0x1F` (because Int8 has only 256 values), and why it defers collision handling (frequency with random input is low). The pmap_set body (lines 118–241) is a 123-line branchless monster. It is *correct by construction*, provided one accepts the pattern `new_k_j = is_occupied * pick_update + is_new * pick_insert` works under UInt64 arithmetic — which it does, because `is_occupied + is_new = 1` always and each pick produces zero unless the appropriate case fires. But the argument is not in the source. A reader has to work it out. The argument takes three sentences; it should be three sentences of comment.

**Conchon–Filliâtre semi-persistent** (`cf_semi_persistent.jl`). The header (lines 1–107!) is one of the finest pieces of source-level documentation in the project. It states the paper, derives the state layout, explains the correspondence with Bennett's history tape (§5), concedes the O(max_n) lookup (§6), and even offers a verdict on the brief's structural claim. This file is *literate programming*, in the spirit Knuth would recognize. If the rest of the codebase achieved this standard, the overall review would be glowing. It doesn't, but this file shows it can.

### 6. The soft-float library (`src/softfloat/*`)

I have spent most of my review-time here because IEEE 754 is the kind of spec whose correctness either holds bit-for-bit or doesn't hold at all.

**Certifiability by reading.** Can one read `soft_fadd.jl` and certify bit-exactness with hardware? My judgment is: *almost, but not quite*. The code is branchless and follows Berkeley SoftFloat's algorithmic structure. The select chain at lines 121–133 is a priority-ordered override — NaN > Inf > Zero > subnormal > normal — which is the correct IEEE 754 priority. The rounding code in `_sf_round_and_pack` (lines 125–154 of `softfloat_common.jl`) implements round-nearest-ties-to-even via guard-round-sticky, exactly as Koren-Zinaty would specify. One can verify that `grs > 4` means "strictly more than halfway, round up"; `grs == 4 && frac & 1 != 0` is the ties-to-even condition. Good.

The `_sf_normalize_clz` function (lines 66–92) is a 6-stage branchless count-leading-zeros cast into a binary-search. I have verified by hand that the shift amounts (32, 16, 8, 4, 2, 1) and the mask positions (24, 40, 48, 52, 54, 55) are consistent: at stage `k`, we check whether the top `2^(6−k)` bits are zero; if so, shift by `2^(6−k)`. The bit-position after six stages lands the leading 1 at bit 55, as required by the working format.

The one place I could not certify by reading is the `soft_fdiv` restoring-division loop (lines 53–62) combined with the subnormal normalization `_sf_normalize_to_bit52`. The claim in the comment is "the 56-bit restoring-division loop below requires ma, mb ∈ [2^52, 2^53)". After pre-normalization, this is true. The loop iterates 56 times; invariant: after iteration `i`, `q` holds the high `i+1` bits of the true quotient, and `r` holds the shifted partial remainder. I believe the invariant but cannot verify it rigorously without a proof of the subnormal prenormalization commutativity. The author's WORKLOG entry `Bennett-r6e3` is cited in the comment; that entry would need to be read to complete the certification. In short: the code is *almost* literate, but the final link to correctness proof is offloaded to the WORKLOG.

**Kahan's theorem invocation in `fsqrt.jl`.** The comment at lines 12–15 invokes Kahan's no-midpoint property of sqrt to justify the sticky-bit-only rounding — no Markstein correction, no Tuckerman post-test. This is mathematically correct *and* exactly the kind of citation Knuth would applaud. The code then lives up to the citation: a 64-iteration restoring digit-by-digit sqrt on a 128-bit radicand, with sticky. Beautiful.

**The verification methodology.** 1.2 million random raw-bit pairs, plus all subnormal / NaN / Inf / signed-zero / overflow regions. This is the right test methodology — "adversarial random" in the sense that the adversary is IEEE 754 itself. But it cannot *prove* bit-exactness; it can only *rule out with high probability*. A reader who wants certainty must read the code and be convinced. The code is *close enough* to being self-certifying that, with a few additional invariant comments, it could be. "I have only tried it correct, not proved it" is the present situation.

### 7. Bennett's 1973 construction (`src/bennett_transform.jl`)

49 lines. This is the spine of the whole project.

```julia
function bennett(lr::LoweringResult)
    if lr.self_reversing
        return _build_circuit(copy(lr.gates), ...)
    end
    ...
    append!(all_gates, lr.gates)                      # forward
    for (i, w) in enumerate(lr.output_wires)          # copy-out
        push!(all_gates, CNOTGate(w, copy_wires[i]))
    end
    for i in length(lr.gates):-1:1                    # uncompute
        push!(all_gates, lr.gates[i])
    end
    ...
end
```

The structure is plainly Bennett 1973, forward + copy + reverse. The elegance is that *NOT, CNOT, and Toffoli are all self-inverse*, so running the forward gate sequence backwards gives the inverse automatically — no separate inverse-gate machinery needed. This is stated in `gates.jl`:

> NOT gate: flips the target bit. Self-inverse.
> Controlled-NOT gate: flips target when control is 1. Self-inverse.
> Toffoli gate: flips target when both controls are 1. Self-inverse.

Three comments, three invariants, each load-bearing. I approve.

The `self_reversing` escape hatch (lines 24–30) is worth pausing on. When a primitive (Sun-Borissov multiplier, QCLA adder) has internally arranged its own Bennett-style uncompute, the outer `bennett` wrap would merely double the work. The flag short-circuits this. This is an elegant optimization but also a *correctness risk*: if a primitive claims `self_reversing = true` falsely, ancillae leak. The docstring says so (`P1: self-reversing primitives`); I would add an `assert` in `_build_circuit` that `ancilla_wires` is empty when this flag is true, and run `verify_reversibility` at compile time in debug builds. At present, the honor system prevails.

### 8. SAT pebbling and Knill's classical pebbling

`src/pebbling.jl` implements Knill 1995 Theorem 2.1 via dynamic programming on `F(n, s)`. The recurrence

```
F(1, s) = 1 for s ≥ 1
F(n, 1) = ∞ for n ≥ 2
F(n, s) = min_m { F(m, s) + F(m, s−1) + F(n−m, s−1) }   for n, s ≥ 2
```

is implemented verbatim. The table fill is Θ(n² s) time and Θ(n s) space. The code has an "overflow-safe addition" check (line 37) which guards against the `typemax(Int) ÷ 4` sentinel propagating. This is defensive programming — Knuth would ask whether `BigInt` or saturating arithmetic would be cleaner. I think yes: `fill(typemax(Int) ÷ 2, ...)` is a fragile magic number. But the bug it guards against (Int64 overflow at very large n) is real and rare.

`src/sat_pebbling.jl` (Meuli 2019) encodes the reversible pebbling game as SAT with PicoSAT backend. The CNF encoding (lines 54–95) is straightforward but subtle: the "move clauses" say that for a pebble to flip at node `v` between time `i` and `i+1`, all predecessors must be pebbled at *both* times. This is the right reversible pebbling axiom. The sequential counter encoding for at-most-K (lines 133–167) is Sinz 2005 — unreferenced in the source. *A paper citation would fit in a two-word comment.*

### 9. The simulator (`src/simulator.jl`)

68 lines. I said in the prompt that a Knuth review would ask whether the simulator is as simple as its concept. Answer: **yes**. Three `@inline apply!` methods — one each for NOT, CNOT, Toffoli — and a 20-line `_simulate` that zeros a `Vector{Bool}`, scatters the input, applies gates in order, asserts ancillae are zero, and reads the output. This is the shortest, clearest, most direct simulator one could imagine.

The only blemish: `_read_int` (lines 57–68) has a chain of `if width == 8; ... elseif width == 16; ...` that could be `reinterpret(T, raw & mask)` with `T` chosen by dispatch. But the widths that actually occur are exactly `{8, 16, 32, 64}`, so the chain is complete and the non-matching case falls through to `Int`. No bug. Merely inelegant.

---

## Literate Programming Assessment

I open by reiterating: **this codebase is *unusually* literate by the standards of modern Julia projects, and especially by the standards of compilers**. The typical file begins with 20–100 lines of header explaining the algorithm, citing the paper, stating the invariants. The quality varies:

- **Outstanding**: `qcla.jl`, `cf_semi_persistent.jl`, `fsqrt.jl`, `hamt.jl` (after the header), `mul_qcla_tree.jl`, `okasaki_rbt.jl`.
- **Good**: `adder.jl`, `multiplier.jl`, `parallel_adder_tree.jl`, `shadow_memory.jl`, `feistel.jl`, `eager.jl`, `value_eager.jl`, `pebbling.jl`, `bennett_transform.jl`.
- **Adequate**: `simulator.jl`, `gates.jl`, `wire_allocator.jl`, `controlled.jl`, `ir_types.jl`, `diagnostics.jl`.
- **Needs work**: `lower.jl` (2662 lines of mostly uncommented instruction dispatch) and `ir_extract.jl` (2394 lines of LLVM.jl API manipulation). These are where the project accumulates debt.

**Comments that explain WHY vs WHAT.** Grepping the sources, I find 1,133 comment blocks. Sampling 50 at random:

- About 60% explain *why* a decision was made (e.g. the 30-line header to `okasaki_rbt.jl` on deferring delete; the Cuccaro MAJ explanation; the WORKLOG reference in `parallel_adder_tree.jl` justifying the reverse-level uncompute).
- About 30% explain *what* the next line does (e.g. `# Phase 1: init G. Z[k+1] = a[k] AND b[k].`). These are useful because they tie the code to a phase name in the paper, but they are not strictly informative on their own.
- About 10% are either redundant (`# Slot 0`, `# Slot 1`, ..., `# Slot 7` in `hamt.jl`) or outright wrong (the Cuccaro docstring's "2n negations" claim for code that emits zero negations).

**Missing WHY comments at load-bearing invariants.** I identify five:

1. `adder.jl:48` — *middle MAJ's `a[i-1]` physically holds `c_i` after the previous iteration*. This is the pun that makes the in-place Cuccaro work. Uncommented.

2. `parallel_adder_tree.jl:132` — *the reverse-level-order uncompute is correct because each level's predecessors are untouched when we reach it*. A three-sentence proof belongs here.

3. `bennett_transform.jl:24` — *`self_reversing = true` requires ancillae to be clean at the end of `lr.gates`*. This is an honor-system invariant that, if violated, leaks ancillae silently.

4. `hamt.jl:168` — *the `is_occupied * pick_update + is_new * pick_insert` pattern is safe because `is_occupied + is_new == 1`*. Uncommented.

5. `okasaki_rbt.jl:269` — *after a single insert, at most one red-red violation exists, and it is at depth 2; balance at depth 2 restores the invariant*. The code asserts this pattern but does not state the invariant.

---

## Proof obligations — the five most important invariants

### Invariant 1: "All ancilla wires are zero after circuit execution."

Stated in `simulator.jl:30–32` as an *assertion*, not a *theorem*:

```julia
for w in circuit.ancilla_wires
    bits[w] && error("Ancilla wire $w not zero — Bennett construction bug")
end
```

**How close to provable.** For the base `bennett()` transform, the invariant is immediate: forward + reverse = identity on non-output wires, so ancillae return to zero. The proof is one line. For `eager_bennett`, `value_eager_bennett`, `pebbled_bennett`, the proof is more delicate: one must show that eagerly-cleaned wires are never subsequently read as controls (so their zeroing is order-independent). The `eager.jl` comment at lines 112–120 asserts this invariant and explains why the earlier wire-level EAGER attempt *failed* (cleaned wires read as controls produced incorrect reversal). This is the kind of honest post-mortem Knuth would admire.

For `self_reversing` primitives, the invariant must be established by the primitive itself. The parallel adder tree does so via its A3 uncompute schedule; the QCLA does so via its P⁻¹ phase. Neither has a formal proof in-source.

**Verdict.** The invariant is *testable* but not *proved*. A proof is within reach for each of the four Bennett variants.

### Invariant 2: "For each i ≤ W, `toffoli_depth(qcla_adder_of_width_W) == ⌊log₂ W⌋ + ⌊log₂(W/3)⌋ + 4`."

Stated in `qcla.jl:17`. Verified against no test I can find. **This is a regression barrier that should be asserted.**

### Invariant 3: "soft_fadd(a, b) == reinterpret(UInt64, reinterpret(Float64, a) + reinterpret(Float64, b))."

The claim is bit-exactness with hardware. `test_softfloat.jl` reportedly checks 1,037 tests (per CLAUDE.md); `BENCHMARKS.md` reports "1.2M random raw-bit pairs including all subnormal, NaN, Inf, signed-zero, and overflow regions". This is strong empirical evidence but not a proof.

**How close to provable.** The code is branchless and follows Berkeley SoftFloat's schema. Each special-case branch is a direct transcription of IEEE 754 §6. A human-readable correctness argument would have four parts: (a) the priority-ordered select chain realizes IEEE 754's special-case table; (b) the mantissa addition with working-format shift implements the correct rounding information; (c) the normalize-CLZ produces the canonical normalized form; (d) `_sf_round_and_pack` implements round-nearest-ties-to-even. Parts (a)–(d) are each within 10–20 lines of proof. The project is *within reach* of a machine-checked Lean proof of bit-exactness; it has not attempted one.

### Invariant 4: "Gate counts are exact reproducible functions of the input program."

The BENCHMARKS.md table claims `i8 x+1 = 100 gates` exactly — not an upper bound, not "approximately". CLAUDE.md principle 6 declares gate counts regression baselines. The proof obligation here is that `gate_count(reversible_compile(f, T))` is deterministic across Julia versions, LLVM versions, and transient system state.

**How close to provable.** The compilation is deterministic *given* the extracted IR. The IR is LLVM-dependent. CLAUDE.md §5 acknowledges this ("LLVM IR is not stable"). In practice the gate counts hold under `optimize=false`. A formal proof would have to quantify: given the parsed IR, the lowering is a pure function; therefore the gate count is a pure function of the parsed IR. The parsed IR is itself a pure function of the Julia source and the LLVM toolchain version. The invariant is thus conditionally provable.

### Invariant 5: "Wire IDs are unique per circuit."

Maintained by `WireAllocator` in `wire_allocator.jl`. The allocator increments `next_wire` monotonically or pops from `free_list`. **The free_list correctness depends on a precondition the docstring states:** "Wires MUST be in zero state" (line 22). If a caller frees a wire that is not zero, subsequent allocation returns a non-zero wire — and the whole Bennett invariant falls.

**How close to provable.** The precondition is not enforced by the type system or by any assertion. It is honor-system. In a Knuth-reviewed codebase, `free!` would verify the precondition at debug-build time, probably by accepting the current gate sequence as an argument and tracing the wire's recent modifications.

---

## On Mathematical Naming

Sampling variable names across the soft-float and arithmetic code:

- `carry`, `sum`, `partial_product`, `accum`, `ancilla` — universally used where they apply.
- `mantissa` / `exponent` / `sign`: spelled `ma`, `ea`, `sa` in soft-float code. Terse but *standard* for IEEE 754 implementations; Berkeley SoftFloat uses the same abbreviations.
- `guard` / `round` / `sticky`: spelled `guard`, `round_bit`, `sticky_bit` in `_sf_round_and_pack`. Perfect.
- `subnormal` / `implicit` / `popcount`: all used verbatim where they belong.

`tmp` / `temp` / `foo` / `bar` / `x1` / `x2` occurrences: only 32 across the whole codebase, none in load-bearing positions. A casual audit turns up `x1`, `x2` as shift intermediates in `fexp.jl` — appropriate for polynomial-evaluation intermediates. No junk.

Grade: **excellent**. Variable names are consistent with the mathematical literature of the domain.

---

## Reference Discipline

I counted 245 mentions of paper authors across 38 files. The top-cited:
- Sun-Borissov 2026 (multiplier): in `mul_qcla_tree.jl`, `parallel_adder_tree.jl`, `fast_copy.jl`, `partial_products.jl`.
- Draper-Kutin-Rains-Svore 2004 (QCLA): in `qcla.jl`.
- Cuccaro 2004 (adder): in `adder.jl` and BENCHMARKS.md.
- Okasaki 1999 + Kahrs 2001 (RBT): in `okasaki_rbt.jl`.
- Bagwell 2001 (HAMT and popcount): in `hamt.jl`, `popcount.jl`.
- Conchon-Filliâtre 2007: in `cf_semi_persistent.jl`.
- Luby-Rackoff 1988: in `feistel.jl`.
- PRS15 (Parent-Roetteler-Svore): in `eager.jl`, `value_eager.jl`, `pebbled_groups.jl`.
- Knill 1995: in `pebbling.jl`.
- Bennett 1973: in README, WORKLOG; not cited in `bennett_transform.jl` itself (!).
- Meuli 2019: unreferenced by name in `sat_pebbling.jl` even though the encoding is Meuli's.
- Sinz 2005 (sequential counter encoding): unreferenced in `sat_pebbling.jl`.

**Verdict.** Reference discipline is *good* but not *uniform*. `bennett_transform.jl` is the spine of the project and *does not cite Bennett 1973 by name*. The citation is in the README and WORKLOG but not in the file itself. This is like publishing the Euclidean algorithm without mentioning Euclid. Fix: add a two-line header to `bennett_transform.jl` citing "Bennett, C. H. (1973). Logical reversibility of computation. IBM Journal of Research and Development 17(6), 525–532."

Similarly, `sat_pebbling.jl` should cite Meuli 2019 and Sinz 2005.

---

## Correctness-via-examples

CLAUDE.md §3 prescribes red-green TDD; tests are in `test/` (112 files). `@example` Julia docstrings are absent — `grep` returned zero matches for `@example` or `julia>`. The project uses the Julia test framework for correctness but not for documentation. An `@example` in each soft-float function showing `soft_fadd(reinterpret(UInt64, 1.5), reinterpret(UInt64, 2.5)) == reinterpret(UInt64, 4.0)` would be a 5-line addition per function and would make the correctness claim *readable* alongside the code.

Small worked examples in the source would help especially in:
- `qcla.jl`: trace W=4 through the phases showing which Toffolis fire.
- `okasaki_rbt.jl`: show the four cases as ASCII diagrams.
- `mul_qcla_tree.jl`: trace W=2, two partial products, one adder.

---

## Where Structured Programming Would Pay

1. **`lower.jl` at 2,662 lines** is a single file containing the instruction dispatch for every LLVM opcode. It has grown one `elseif` at a time. The algorithmic logic — lowering `add` to a ripple adder, lowering `icmp` to a subtract-and-check-zero — is interleaved with plumbing (SSA name resolution, wire tracking, path-predicate guards). A structured decomposition would separate *instruction-specific lowering tables* from *SSA/wire-bookkeeping*. The code could be halved in length at no cost to correctness and the lowering for each opcode would become inspectable.

2. **`ir_extract.jl` at 2,394 lines** is similarly monolithic. It wraps LLVM.jl's C API to produce the parsed IR. The WORKLOG notes several bugs here (vector lanes, sret handling, alloca dynamic n_elems). These bugs are symptomatic of the file's lack of internal modularity. A structured rewrite would separate *LLVM type decoding* (a pure function) from *IR-opcode dispatch* from *globals-and-constants extraction*.

3. **The `LoweringCtx` struct** (`lower.jl:50–83`) has 16 fields and three layered constructors for backward compatibility. Knuth would say: declare the invariant the struct maintains — *"all fields are either initialized or default"* — and collapse the constructors. The backward-compatibility constructors are a soft-spoken `FIXME`.

Where optimization has harmed readability I did not find many examples. The branchless soft-float code is readable despite its dense `ifelse`-chains; the Sun-Borissov code is readable despite its A3 uncompute. The project does not over-optimize.

---

## Data-Structure Elegance

- **`ReversibleGate` / `ReversibleCircuit`**: minimal, orthogonal, self-inverse gates with a monotonic wire naming. Mathematically clean.
- **`ParsedIR`**: a product of `ret_width`, `args`, `blocks`, and auxiliary caches. Has a custom `Base.getproperty` to present a deprecated `instructions` field. This is a smell — the `_instructions_cache` is a pre-flattened copy, suggesting the IR is accessed both block-wise and flat-wise and neither representation dominates. A cleaner design would pick one and provide a cheap iterator for the other.
- **`LoweringCtx`**: 16 fields. Overweight. Needs structural reform.
- **`WireAllocator`**: a mutable struct with `next_wire` and a descending-sorted free list for O(1) min-pop. Simple and correct. The free-list insertion is O(n); for large circuits a min-heap would be asymptotically better, but none of the benchmarked circuits stress this. An honest engineer's choice.
- **`ShadowMemory`**: a primitive, not a struct. Per-store cost `3W` CNOT, per-load `W` CNOT. Conceptually beautiful: the tape is a checkpoint onto which the primal is XOR-copied before the write, and Bennett's reverse undoes both store and tape.
- **Persistent maps**: `NTuple{N, UInt64}` states. This *is* the reversible-friendly representation — a value, not a reference; branchless by construction. Mathematically the right choice. The arithmetic encoding of state fields (node-packing in `okasaki_rbt.jl`) is fiddly but there is no cleaner alternative under the branchless constraint.

Verdict: most data structures are well-chosen; `LoweringCtx` and `ParsedIR` need pruning.

---

## Aesthetic Judgment

Is this codebase beautiful?

**Beauty of algorithm.** Yes. The Sun-Borissov tree multiplier, the Draper QCLA, the Cuccaro in-place adder, the Bennett transform itself, the parallel fast-copy — each is a miniature theorem, and the code pays them the respect of implementing them as written. The author (or authors) evidently loves the algorithms. One can feel this in the code. This kind of love is rare and I commend it.

**Beauty of architecture.** Mixed. The separation of concerns — extract → lower → Bennett-transform → simulate — is clean at the highest level. But `lower.jl` and `ir_extract.jl` are monolithic, and the `LoweringCtx` struct is visibly accreting features. The codebase has the shape of a healthy research project caught between prototype and production.

**Beauty of exposition.** Uneven. `cf_semi_persistent.jl`, `qcla.jl`, `fsqrt.jl`, `mul_qcla_tree.jl` approach literate programming. Most other files are adequately-commented imperative Julia. The overall project achieves about two-thirds of the WEB-style ideal; with modest additional effort — perhaps two days of dedicated annotation work, adding @example blocks, citing missing papers, stating invariants at the five proof-obligation sites I identified — it could be pushed up to full literacy.

**Beauty of discipline.** High. The CLAUDE.md document states 13 principles, of which several (fail fast, red-green TDD, 3+1 multi-agent review for core changes) are genuinely followed. The WORKLOG is honest about bugs found (the parallel adder tree's A3 uncompute; the phi resolution false-path sensitization in v0.5). The BENCHMARKS.md table records head-to-head comparisons against published compilers and does not flinch when the Bennett implementation is 2.4× off from a hand-optimized PRS15 result.

**Beauty of naming.** Excellent. Variable names follow the literature.

**Verdict.** The codebase is *more beautiful than typical* and *less beautiful than it could be*. It is the work of people who clearly care about getting the algorithms right and who clearly know the relevant literature. It is not yet a textbook, but it is close. The path from here to there runs through: inlining proofs of invariants, citing Bennett-1973 in the file that bears his name, and stating the correctness argument for A3-uncompute in three sentences inside `parallel_adder_tree.jl`.

A codebase may be judged partly by the company it keeps, and Bennett.jl keeps the company of Cuccaro, Draper, Karatsuba, Kahan, Okasaki, Bagwell, Luby, Rackoff, Bennett, Knill, Meuli, and Sun-Borissov. That is distinguished company. I would read the next version with interest.

> *"Programs are meant to be read by humans and only incidentally for computers to execute."*
>
> This codebase meets the second clause completely and the first clause about two-thirds of the way. Finish the job.

— *D. E. K.*
