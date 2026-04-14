# parallel_adder_tree Design Consensus — A1 (Bennett-a439)

Synthesized from `parallel_adder_tree_proposer_A.md` and
`parallel_adder_tree_proposer_B.md`. Proposers diverged on
scheduling/uncompute — proposer A picked simpler linearized execution
with 2× Toffoli-depth penalty; proposer B picked interleaved Schedule B
that matches the paper's closed-form depth formula. This consensus
**chooses A's simpler design** for the first implementation, with B's
optimizations filed as follow-up tightening.

## Rationale

Both proposers independently arrived at the same fundamental shape (tree
of QCLAs over shift-aliased partial products; level-d−2 uncomputed while
level d computes). The split is purely on the scheduler:

- **Schedule A (linearized, proposer A)** — emit level-d forward gates,
  then level-(d−2) inverse gates, in strict sequence. Preserves Toffoli
  *count* exactly but adds up to 2× to Toffoli-*depth*.
- **Schedule B (interleaved, proposer B)** — round-robin merge the
  per-depth-layer gates of forward-d and inverse-(d−2). Preserves the
  paper's closed-form depth of `3 log²n + 7 log n + 12` Toffoli-depth
  but requires a new `_emit_interleaved!` scheduler helper and layer-
  by-layer analysis of each gate's wire set.

For the **first landing**, Schedule A wins on: testability (straightforward
RED/GREEN cycle), low surface area (no new helper type), and
reviewability (no subtle wire-disjointness proof obligations). X3
(paper-match within ±10%) will likely fail Toffoli-depth on this design
— when that happens, we file a tightening issue and migrate to Schedule
B as a pure optimization pass.

Schedule A's 2× depth cost hurts headline numbers but **does not affect
correctness**; correctness-first is the project principle (CLAUDE.md §3
red-green TDD).

## API

```julia
emit_parallel_adder_tree!(
    gates::Vector{ReversibleGate},
    wa::WireAllocator,
    pp::Vector{Vector{Int}},   # W partial products, each of W wires
    W::Int;
    reuse_pool::Vector{Int}=Int[],   # optional freed ancillae for recycling
) -> Vector{Int}   # (2W)-wire result register; final sum bits LSB-first
```

Input contract:
- `pp` has length W; each entry is length W.
- Every entry is freshly-allocated or caller-owned (we read them but
  don't restore them — level-0 is never uncomputed by this function).
- `reuse_pool` is optional; if non-empty, allocation requests prefer
  these wires before calling `allocate!(wa, …)`. Concretely, A2 ignores
  this and always calls `allocate!`; A3 can be upgraded to use the pool.

Output contract:
- Result register of exactly `2W` wires. On return: `result[i]` is
  bit `i-1` of `xy`, for `i = 1..2W`. `result[2W+1]` does not exist
  (carry from the top adder is absorbed into the `2W`-wide target).
- Levels 0..D−3 are uncomputed (wires back to zero); levels D−2 and D−1
  are retained (paper §II.D.2 — outer algorithm steps 5–7 clean those up
  via the multiplier's X1 assembly, not this submodule). **This means
  `emit_parallel_adder_tree!` is NOT self-reversing in the
  CLAUDE.md #13 sense.** The self-reversing flag belongs to the outer
  `lower_mul_qcla_tree!`.

## Algorithm (consensus pseudocode)

```julia
function emit_parallel_adder_tree!(gates, wa, pp::Vector{Vector{Int}}, W::Int;
                                   reuse_pool::Vector{Int}=Int[])
    W >= 1 || error("emit_parallel_adder_tree!: W must be >= 1")
    length(pp) == W || error("emit_parallel_adder_tree!: expected $W partial products, got $(length(pp))")
    all(p -> length(p) == W, pp) || error("emit_parallel_adder_tree!: every partial product must have W=$W wires")

    D = ceil(Int, log2(max(W, 2)))

    # level[d][r] is the register holding α^{(d,r)}, length n + 2^d
    # (logical length; some high bits may be unallocated because shift
    # aliases into the output register as described below).
    level = Vector{Vector{Vector{Int}}}()
    push!(level, [p for p in pp])     # level 0 is the input partial products

    # Record adder-invocations so we can uncompute level d-2 later.
    adder_records = Vector{Vector{AdderRecord}}()   # one row per level
    push!(adder_records, AdderRecord[])             # empty row for level 0

    for d in 1:D
        n_at_d_minus_1 = length(level[d])
        len_parent = length(level[d][1])   # = n + 2^{d-1}
        shift = 1 << (d-1)                 # power-of-2 shift factor

        level_d = Vector{Vector{Int}}()
        records_d = AdderRecord[]

        # Process pairs (2r, 2r+1) from level d-1
        for r in 0:(div(n_at_d_minus_1, 2) - 1)
            left  = level[d][2r + 1]
            right = level[d][2r + 2]

            # Allocate output register of size n + 2^d (one bit larger than parent)
            out_len = len_parent + shift
            out = allocate!(wa, out_len)

            # Call lower_add_qcla! on (left, shifted right) into out.
            # "shifted right" is represented by:
            #   - positions 1..shift of the virtual operand: logical zeros
            #   - positions shift+1..shift+len_parent: right[1..len_parent]
            # We realize this via a concrete zero-padded operand built by
            # copying (no gates — zeros are implicit in fresh ancilla).

            gs = length(gates) + 1
            ws = wa.next_wire
            _emit_tree_adder!(gates, wa, left, right, out, len_parent, shift)
            ge = length(gates)
            we = wa.next_wire - 1

            push!(records_d, AdderRecord(gs, ge, ws, we, out, left, right, len_parent, shift))
            push!(level_d, out)
        end

        # If n_at_d_minus_1 is odd, bubble the leftover child up unchanged.
        if isodd(n_at_d_minus_1)
            push!(level_d, level[d][end])
            push!(records_d, AdderRecord(0, 0, 0, 0, level[d][end], Int[], Int[], 0, 0))
        end

        push!(level, level_d)
        push!(adder_records, records_d)

        # Schedule A: uncompute level d-2 right here, inline.
        if d >= 2
            _replay_inverse!(gates, adder_records[d - 1])    # zeros level d-2 registers
        end
    end

    # Final result is level[D+1][1]  (0-indexed: level D has one entry)
    # Truncate / extend to exactly 2W wires.
    result = level[D + 1][1]
    return length(result) >= 2W ? result[1:2W] : _pad_with_zeros(result, 2W, wa)
end
```

`_emit_tree_adder!(gates, wa, left, right, out, n, shift)` emits the
three paper stages:

1. `suffix_copying`: CNOT `left[k]` into `out[k]` for `k = 1..shift`.
2. `overlapping_sum`: call `lower_add_qcla!(gates, wa, left[shift+1:n+shift], right[1..n], n)` (matching widths); CNOT its W+1-bit result into `out[shift+1..n+shift+1]`. Then allocate a scratch register, copy, and run inverse QCLA to restore — **proposer A's "Strategy α"** (uses black-box QCLA; costs O(n log n) extra Toffolis, within paper's headroom).
3. `carry_propagation`: broadcast the carry from stage 2 into `out[n+shift+1..n+shift+shift]` using a modified QCLA where the second operand is logical zero. Proposer A's construction: allocate k-wire zero register, CNOT the carry onto its LSB, call `lower_add_qcla!` again, copy back, and inverse-QCLA to uncompute the zero scratch.

**`_replay_inverse!(gates, records)`** iterates each record and emits
`gates[record.gs:record.ge]` in reverse order, appended to `gates`. Each
gate is self-inverse; the inverse replay zeroes every wire the forward
adder wrote, including all internal ancillae `record.ws..record.we`.

## Ancilla bound

Proposer A documents ~3n² ancillae due to the "pin internal wires until
inverse replay" scheme. Paper's 2n² bound requires proposer B's
Schedule B with pool recycling. This consensus accepts the 3n² bound
for first landing; X3 follow-up can tighten to 2n² via pool recycling
if needed for paper-match. Specifically, once an adder at level d is
fully consumed by level d+1, its wires can be returned to the pool for
reuse by subsequent level-(d+1) adders. Deferred.

## Cost formulas (A2+A3 combined, Schedule A)

| W  | Toffoli (predicted) | Toffoli-depth | Ancilla (≤) |
|----|---------------------|---------------|-------------|
|  4 | ~80                 | ~12           | 48          |
|  8 | ~500                | ~20           | 192         |
| 16 | ~3000               | ~35           | 768         |
| 32 | ~17000              | ~55           | 3072        |

These are upper-bound estimates from proposer A; actual numbers will
be pinned in A2/A3 tests. Compare to paper's Table III row for
`parallel_adder_tree` alone: Toffoli = `10n² − n log n` (paper's
tighter version: 152/608/2400/9600 at W=4/8/16/32), Toffoli-depth =
`3 log²n + 7 log n + 12` (28/40/56/72). Our Schedule A is ~2× the
Toffoli-depth and ~2× the Toffoli count (consistent with inverse-replay
costing the same as forward).

## Worked W=4 trace

Level 0: 4 partial products α^(0,0), α^(0,1), α^(0,2), α^(0,3), each 4 bits.

Level 1: two adders.
- Adder 1-0: `α^(1,0) = α^(0,0) + 2·α^(0,1)` — 5-bit result.
- Adder 1-1: `α^(1,1) = α^(0,2) + 2·α^(0,3)` — 5-bit result.
No uncompute at d=1 (no d-2 level).

Level 2: one adder.
- Adder 2-0: `α^(2,0) = α^(1,0) + 4·α^(1,1)` — 8-bit result = xy.
After d=2 computation, uncompute level 0 (d−2 = 0): replay inverse of
all 4 partial-product adders … wait, level 0 is the INPUT partial
products, not computed by this function. Don't uncompute them. So at
W=4 there's nothing to uncompute (level 1 remains).

At W=8: tree has 3 levels. Level 1 has 4 adders, level 2 has 2, level 3
has 1. When d=3 computes, uncompute level 1. Level 2 stays (that's
d−1). After exit, levels 2 and 3 are both intact in wires (not
uncomputed).

## Edge cases

- **W = 1**: tree is trivial. `emit_parallel_adder_tree!` returns
  `pp[1]` extended to 2 wires. Zero adders, zero gates emitted.
- **W = 2**: D = 1. One adder at level 1. No level d−2 to uncompute.
- **W not a power of 2**: odd child bubbles up unchanged via
  proposer A's "orphan pass-through". Verified: 5, 6, 7, 9, 12 in the
  A3 test plan.

## Test plan (A2 RED target first)

`test/test_parallel_adder_tree.jl` — live in A2/A3, iterating through
the following as the implementation progresses:

1. **W=1**: trivial; returns pp[1] padded to 2 wires.
2. **W=2**: one adder; verify sum for all (pp[1], pp[2]) ∈ {0..3}×{0..3}.
3. **W=4 exhaustive forward correctness (A2 GREEN contract)**: for all
   (x, y) ∈ [0,16) × [0,16), build pp = [y_i · x for i = 0..3] using the
   actual partial-products path, feed to `emit_parallel_adder_tree!`,
   verify `result == x * y mod 256`.
4. **W=4 uncompute verification (A3 GREEN contract)**: for all
   (x, y), after `emit_parallel_adder_tree!` returns, the input
   `pp` registers are unchanged (their wire values equal what they
   held at entry).
5. **W=8 correctness sample**: 200 random (x, y) pairs.
6. **Ancilla-zero check**: all wires allocated during
   `emit_parallel_adder_tree!` (except level-D−1 and level-D registers)
   return to zero after execution.
7. **Gate-count regression pin** at W=4/8 for Toffoli and
   Toffoli-depth (values TBD during implementation; pinned at first
   GREEN run, then maintained per principle 6).

## Invariants (principle 4)

1. Every adder's internal ancilla wires are pinned until its inverse
   replays; no two live adder records alias internal wires.
2. After `_replay_inverse!(records_d_minus_2)`, all wires recorded in
   `record.ws..record.we` for records in `records_d_minus_2` are zero.
3. `emit_parallel_adder_tree!` never mutates `pp` entries — they are
   read-only inputs for the duration.
4. Failures in operand size, width, or pool allocation `error(…)` with
   explicit diagnostic text (principle 1).

## Deferred to X3 / follow-up

1. Schedule B interleaving (proposer B's plan) — needed to match paper's
   `3 log²n + 7 log n + 12` Toffoli-depth. File as follow-up when X3
   measurements show the gap.
2. Ancilla pool recycling tight to 2n² — requires pool-manager refactor.
3. Fused `lower_add_qcla_shifted!` / `lower_add_qcla_into!` variants
   (proposer B's mandatory primitives for Schedule B). Pre-conditions
   for the depth-optimization pass above.

## Structures (A2 introduces)

```julia
struct AdderRecord
    gs::Int                         # gate index (start of this adder's block)
    ge::Int                         # gate index (end)
    ws::Int                         # first internal wire
    we::Int                         # last internal wire
    output::Vector{Int}             # output register
    left::Vector{Int}               # reference to left operand (for trace)
    right::Vector{Int}              # reference to right operand
    len::Int                        # width of overlap stage
    shift::Int                      # shift amount (= 2^{d-1})
end
```

Adder records are kept in `level_records[d]` for levels d = 0..D, so
`_replay_inverse!` can look up which adders to reverse.
