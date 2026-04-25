## Session log — 2026-04-16 — soft_fma (IEEE 754 binary64 FMA) (Bennett-0xx3)

First IEEE 754 binary64 reversible fused multiply-add with single
rounding in the quantum / reversible-circuit literature. Häner-Soeken-
Roetteler-Svore 2018 (arXiv:1807.02023) implements only FP add and mul;
§7 names FMA as a useful combination (Horner scheme, Knuth 1962) but
does not implement it. The 2024 comprehensive survey (arXiv:2406.03867)
§2.3 enumerates every known reversible-FP circuit: "no mention of fused
multiply-add (FMA)", "only single-precision (binary32) implementations".
AnanthaLakshmi-Sudha 2017 (Microprocessors and Microsystems v.51) is
adiabatic-CMOS FP32 with unverified single-rounding semantics — not in
the quantum Clifford+T regime.

### Algorithm

Berkeley SoftFloat 3 `s_mulAddF64.c` SOFTFLOAT_FAST_INT64 path, ported
branchless. 128-bit intermediate (two UInt64 limbs). Berkeley's scaling
convention: `ma << 10`, `mb << 10`, `mc << 9`. Full design doc:
`docs/design/soft_fma_consensus.md`.

Pipeline:
1. Unpack all three operands + special predicates + subnormal
   pre-normalization via `_sf_normalize_to_bit52`.
2. 53×53 → 128-bit product via new helper `_sf_widemul_u64_to_128` (32×32
   split — general enough for 63-bit Berkeley-scaled inputs).
3. Berkeley line-122 normalize: `if p_hi < 2^61, <<1, expZ--`. Leading 1
   at bit 125 of 128-bit.
4. Alignment: if `expDiff < 0`, shift-right-jam product by `-expDiff`;
   if `expDiff > 0`, shift c. Special: `expDiff == -1 & opp sign` uses
   `>>1 with sticky` (Berkeley line-144 precision-preservation trick).
5. Add and subtract computed unconditionally; select on `same_sign`.
6. Opposite-sign underflow detect → `_neg128`, sign flip.
7. Renormalize: stages handle bit-63 and bit-62 pre-shifts (possible
   after hi_zero fold or same-sign add carry), then 128-bit CLZ to
   leading-1-at-bit-61 via `_sf_clz128_to_hi_bit61`. Crucial: the CLZ
   propagates bits from `wr_lo` into `wr_hi` at each shift stage —
   single-limb CLZ loses precision (bug found during M4).
8. Collapse to 56-bit working format (`>>6`, sticky from bits 0-5 of hi
   plus all of lo).
9. `_sf_handle_subnormal` + `_sf_round_and_pack` reused verbatim.
10. Priority-ordered select chain (NaN strictly last).

### Helpers added in `src/softfloat/softfloat_common.jl`

All branchless `@inline`. No UInt128.

- `_sf_widemul_u64_to_128(a, b)` — general 64×64 → 128 via 32×32 split.
- `_shiftRightJam128(hi, lo, dist)` — Berkeley semantics;
  `dist < 0`, `0 < d < 64`, `64 ≤ d < 128`, `d ≥ 128` cases all
  computed, selected via `ifelse` ladder.
- `_add128`, `_sub128`, `_neg128`, `_shl128_by1`, `_shr128jam_by1`.
- `_sf_clz128_to_hi_bit61(hi, lo, e)` — 128-bit CLZ; stages shift both
  limbs, bringing wr_lo bits up into wr_hi.

### Bugs hit and fixed (for future agents)

1. **Off-by-one in CLZ target**: first version targeted bit 62 (matching
   Berkeley's `softfloat_roundPackToF64`'s implicit-1 position). But our
   `_sf_round_and_pack` expects leading 1 at bit 55 of wr_56; the natural
   shift from Berkeley's post-normalize (bit 125 = bit 61 of hi) to bit
   55 is `>> 6`. Targeting bit 62 followed by `>> 7` gave same mantissa
   but drop-one-exponent. **Fix**: target bit 61 directly
   (`_sf_clz128_to_hi_bit61`); `wr_56 = wr_hi_norm >> 6`.

2. **Single-limb CLZ loses precision**: a single-limb CLZ on `wr_hi`
   alone discards bits of `wr_lo` that should migrate up during left-
   shift. Kahan witness `fma(1-2^-53, 1-2^-53, -1)`: correct result is
   `-2^-52`, single-limb CLZ gives `-(255/128) · 2^-53` — mantissa bits
   lost. **Fix**: 128-bit joint CLZ that propagates `lo >> (64-k)` into
   `hi` at each shift stage.

3. **Sign-flip rule was wrong in the c-dominated case**: original code
   used `result_sign = nominal_sign ⊻ underflow_flag`. For `expDiff < 0`
   (c dominates), this double-flipped. **Fix**: `result_sign = underflow
   ? sc : sign_prod`. This works across all cases (same-sign: underflow
   always false → sign_prod = sc; opposite-sign: underflow picks whoever
   actually dominated in magnitude).

4. **Berkeley's bit-63 check defensiveness**: never fires in practice
   given the <<10/<<9 scaling convention (same-sign add max reaches
   2^63-ε, not 2^63). But POST-hi_zero-fold, wr_hi_folded CAN have bit
   63 set (if wr_lo had its MSB set pre-fold). **Fix**: two-stage
   pre-normalization (bit-63 then bit-62 shift) before CLZ.

### Test coverage

`test/test_softfma.jl` (~280 LOC):
- 10 hard cases (Kahan witness, exact cancellation → +0 RNE, Inf·0 → NaN,
  expDiff=-1 opposite-sign precision trick, signed-zero combine, NaN
  propagation, Inf clash, subnormal mixed-scale, overflow, fma(a,b,0)).
- Random sweeps: 50k normal range, 25k raw-UInt64 (all regions), 10k
  subnormal-input forced (Bennett-fnxg), 10k cancellation region (c ≈
  -a·b).
- All 85k+ triples bit-exact vs `Base.fma`.

End-to-end circuit: `test/test_float_circuit.jl` — 11 inputs including
Kahan, cancellation, subnormal, Inf·0, NaN. All bit-exact.
`verify_reversibility` passes.

### Files changed

- `src/softfloat/softfloat_common.jl` — +8 helpers (~220 LOC).
- `src/softfloat/fma.jl` — new file (~200 LOC).
- `src/softfloat/softfloat.jl` — `include("fma.jl")`.
- `src/Bennett.jl` — export `soft_fma`; `register_callee!(soft_fma)`.
- `test/test_softfma.jl` — new (~280 LOC).
- `test/test_float_circuit.jl` — add `soft_fma circuit` testset.
- `test/runtests.jl` — include new test file.
- `docs/design/soft_fma_consensus.md` — design doc from 3 research
  subagents (software algorithm, reversible gate cost, quantum
  literature).
- `BENCHMARKS.md` — add soft_fma row.
- `WORKLOG.md` — this entry.

### Research methodology (mirror for future soft-float primitives)

Three parallel research subagents dispatched:

1. **Software algorithm survey** — read Berkeley SoftFloat 3
   `s_mulAddF64.c` (496 lines), `s_shiftRightJam128.c`, musl `fma.c`
   (183 lines) verbatim. Recommended Berkeley FAST_INT64 path, 128-bit
   intermediate. Agent saved sources to `/tmp/` on its workspace;
   reproducible via WebFetch from GitHub mirror.
2. **Reversible gate cost analysis** — estimated 350-420k gates for
   Alg (2) 160-bit intermediate. Correct on methodology (branchless
   ifelse doesn't save gates vs case-split, ripple add for gate
   minimality, raw-product hoist opportunity) but wrong on width:
   160 bits overprovisions; Berkeley's 128 is provably sufficient.
3. **Quantum literature survey** — Häner 2018 §7 explicitly flags FMA
   as a known combination but does not implement; 2024 comprehensive
   survey §2.3 confirms no reversible FMA in any precision. Novelty
   claim documented with citations.

All three converged on the Berkeley algorithm. Resolution of width
disagreement (128 vs 160): ground truth (Berkeley's deliberate design
choice, battle-tested) trumps estimation. Actual implementation is
128-bit.

### Gate count vs plan

| Target | Estimate | Actual |
|--------|---------:|-------:|
| Gate count (plan A budget) | 300-400k | 447,728 |
| Toffoli | 110-140k | 148,340 |
| T-count | ~1M | 1,038,380 |

Actual is 10% over the upper plan estimate. Deltas vs Agent 2's estimate:
- Used general 32×32 widemul (not 27×26 reuse — wouldn't fit 63-bit
  Berkeley-scaled inputs).
- Added two-stage bit-63/bit-62 pre-normalize before CLZ (~2k gates).
- 128-bit CLZ is wider per-stage than the single-limb estimate.

Trade-off accepted: 48k more gates for correctness on the full Kahan-
class edge cases.

### Deferred / follow-ups

- `soft_fms` (fused multiply-subtract) = `soft_fma(a, b, c ⊻ SIGN_MASK)`.
  Trivial; file as separate issue if Julia emits `llvm.fmsub.f64` in
  transcendentals.
- Hoist `soft_fmul`'s 27×26 product into the same shared helper
  architecture. Would require replacing the 32×32 widemul with a 27×26
  variant (or making `_sf_widemul_u64_to_128` dispatch by input width).
  Modest gate-count savings; not on critical path.
- Lowering-level `_sf_fma_fused_wide_add!` primitive if further gate
  reduction is needed for the transcendental roadmap. Estimated
  savings ~20-30% of `soft_fma` cost via shared carry chain.

---

## [archived] Pre-0xx3 NEXT AGENT plan — 2026-04-16

Original pre-implementation plan content preserved at commit 71caa5b.

---

## Reference note — 2026-04-16 — Simulator architecture (general)

For future agents puzzled by what `simulate(circuit, x)` actually does: it
is a **deliberately minimal classical bit-vector simulator**, not a quantum
one. Total surface area is ~50 lines in `src/simulator.jl` plus the
`verify_reversibility` helper in `src/diagnostics.jl`.

### Core loop (`src/simulator.jl:14-35`)

```julia
function _simulate(circuit, inputs)
    bits = zeros(Bool, circuit.n_wires)        # one Bool per wire
    # load inputs into circuit.input_wires positions (LSB-first)
    for gate in circuit.gates                  # sweep gates in order
        apply!(bits, gate)
    end
    for w in circuit.ancilla_wires             # Bennett invariant safety net
        bits[w] && error("Ancilla wire $w not zero — Bennett construction bug")
    end
    return _read_output(bits, circuit.output_wires, circuit.output_elem_widths)
end
```

### Three gate kernels (`src/simulator.jl:1-3`)

One-line bit-XORs — that is the entire ISA:

```julia
apply!(b, g::NOTGate)     = (b[g.target] ⊻= true)
apply!(b, g::CNOTGate)    = (b[g.target] ⊻= b[g.control])
apply!(b, g::ToffoliGate) = (b[g.target] ⊻= b[g.control1] & b[g.control2])
```

### Two layered safety checks

1. **Per-call ancilla zero check** (`simulator.jl:30-32`) — after the gate
   sweep, every wire in `circuit.ancilla_wires` must be 0 or we crash with
   "Bennett construction bug". This is the on-the-fly check that catches
   uncomputation failures during normal simulation.

2. **`verify_reversibility(c; n_tests=100)`** (`diagnostics.jl:145`) — the
   stronger guarantee. Runs forward then reverse (`Iterators.reverse(c.gates)`,
   each gate is self-inverse) over `n_tests` random inputs and asserts that
   *every wire* (not just ancillae) returns to its starting state. Catches
   the failure mode where ancillae happen to return to 0 by coincidence on
   the tested input but the circuit isn't actually reversible.

### Output unpacking

`_read_output` packs result bits back into native Julia ints via `_read_int`:
single-element output → `Int8/16/32/64` (matched to width); multi-element
output (insertvalue tuple return) → `Tuple{Int...}`. Return type is
inherently unstable — depends on `circuit.output_elem_widths`.

### Cost

O(n_gates) per simulation call, each gate is a single Bool XOR. A 3M-gate
circuit (e.g. `soft_exp2_fast`) simulates in ~1-3 seconds; a 5M-gate
circuit (`soft_exp` bit-exact) in ~2-5 seconds. This is why per-input
exhaustive-sweep tests on `Float64` end-to-end circuits cap at ~15-20
inputs per testset — not a fundamental limit, just a CI-time tradeoff.

### Why classical, not quantum?

Bennett's theorem: a classically reversible circuit (correct on every
basis state) is automatically quantum-reversible (correct on superpositions).
So the classical simulator is sufficient to prove **construction
correctness** — that the gate sequence implements `(x, 0) → (x, f(x))`
with all ancillae back to zero on every classical input.

What the classical simulator does *not* do: prove that the circuit gives
the right answer when run on a superposition of inputs. That's
**quantum-control validation**, which is Sturm.jl's domain — Bennett.jl
just emits the gate-level reversible computation that Sturm.jl wraps in
quantum control via `when(qubit) do f(x) end`.

### Controlled circuits (`src/controlled.jl`)

`controlled(c)` returns a `ControlledCircuit` wrapping every gate with a
control: NOT→CNOT, CNOT→Toffoli, Toffoli→4-gate decomposition with a
reusable ancilla (`promote_gate!`). The result has a fresh control wire
and is simulated by the same loop after dispatching `apply!` on the
promoted gate sequence. So the simulator surface area stays at three
gate kernels even for controlled circuits.

---

