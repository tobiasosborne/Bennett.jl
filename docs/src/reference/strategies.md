# Strategy Reference

*A complete lookup table for every strategy knob in Bennett.jl: the `add=`/`mul=`/`target=` arithmetic selectors, the compile-level `strategy=` selector, the six space-time `BennettStrategy` schedulers, and the five reversible-memory lowerings. Dry and exhaustive — for the "why", read [the architecture guide](../explanation/architecture.md); to get started, follow [the tutorial](../tutorials/first_circuit.md).*

All knobs are fields of the exported [`CompileOptions`](../reference/api.md) `@kwdef` struct
(`src/Bennett.jl`), which is the single source of truth for defaults. Pass them as
keyword arguments to `reversible_compile`, or bundle them:

```julia
using Bennett
opts = CompileOptions(add = :cuccaro, fold_constants = false)
c = reversible_compile(x -> x + Int8(1), Tuple{Int8}, opts)
```

`gate_count` returns a `NamedTuple`, not an `Int`; all examples below show the
exact returned value.

```julia
c = reversible_compile(x -> x + Int8(1), Int8)   # all-default kwargs
gate_count(c)            # => (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
ancilla_count(c)         # => 25
t_count(c)               # => 84      (== 7 * Toffoli)
toffoli_depth(c)         # => 12
depth(c)                 # => 19
verify_reversibility(c)  # => true
```

---

## `reversible_compile` options at a glance

The thirteen `CompileOptions` fields (`src/Bennett.jl`). "Overloads" lists which
`reversible_compile` entry points consume each field; on the `ParsedIR` overload,
a non-default `optimize`, `bit_width`, or `strategy` raises `ArgumentError`, and on
the `Float64` overload a non-default `bit_width` raises `ArgumentError`.

| Field | Default | Domain | Role | Overloads |
|---|---|---|---|---|
| `optimize` | `true` | `Bool` | run LLVM `-O` before extraction | Tuple, Float64 |
| `max_loop_iterations` | `0` | `Int` | unroll bound for data-dependent loops (`0` = auto) | all |
| `compact_calls` | `false` | `Bool` | inline registered callees compactly | all |
| `bit_width` | `0` | `Int` | override width (`0` = native); **Tuple overload only** | Tuple |
| `add` | `:auto` | `:auto :ripple :cuccaro :qcla` | adder lowering — see [below](#adder-selection-add) | all |
| `mul` | `:auto` | `:auto :shift_add :qcla_tree` | multiplier lowering — see [below](#multiplier-selection-mul) | all |
| `strategy` | `:auto` | `:auto :tabulate :expression` | compile path (lookup table vs. expression graph) | all |
| `fold_constants` | `true` | `Bool` | constant-fold during lowering | all |
| `target` | `:gate_count` | `:gate_count :depth :reversible_vm` | optimization objective / backend — see [below](#objective-and-backend-target) | all |
| `auto_self_reversing` | `true` | `Bool` | infer `lr.self_reversing` (halves gate count on self-clean circuits) | all |
| `mem` | `:auto` | `:auto :persistent :heap` | memory subsystem dispatch | all |
| `persistent_impl` | `:linear_scan` | `:linear_scan :okasaki :hamt :cf` | persistent-map backing structure | all |
| `hashcons` | `:none` | `:none` | hash-consing strategy (only `:none` wired) | all |

Supported argument types: `Int8/16/32/64`, `UInt8/16/32/64`, `Float64`, `Bool`,
and flat concrete `NTuple{N,T}` of those. **`Float32` is rejected** (no native
f32 arithmetic primitives; see `src/softfloat/fpconv.jl`).

---

## Adder selection (`add=`)

`add` chooses the lowering for every `add`/`sub` LLVM opcode. `_pick_add_strategy`
(`src/lowering/arith.jl`) resolves the symbol per-operation; explicit values pass
through unchanged. `W` is the operand bit-width.

| `add=` | Lowering (`src/`) | Gate cost | Toffoli-depth | Ancilla | Paper |
|---|---|---|---|---|---|
| `:ripple` | `lower_add!` (`adder.jl`) | `5W-2` total, `2(W-1)` Toffoli | `2(W-1)` (serial carry) | `W` (carry) | ripple-carry full adder (classic) |
| `:cuccaro` | `lower_add_cuccaro!` (`adder.jl`) | `6W-5` total: `2W-3` Toffoli, `4W-2` CNOT, `0` NOT | `≈ 2W` | `1` | Cuccaro, Draper, Kutin, Moulton 2004 (§3.5) |
| `:qcla` | `lower_add_qcla!` (`qcla.jl`) | `5W − 3·popcount(W) − 3·⌊log₂W⌋ − 1` Toffoli, `3W-1` CNOT | `⌊log₂W⌋ + ⌊log₂(W/3)⌋ + 4` | `W − popcount(W) − ⌊log₂W⌋` | Draper, Kutin, Rains, Svore 2004, arXiv:quant-ph/0406142 (§4.1 Thm 1, `W≥4`) |
| `:auto` | resolves to **`:ripple`** | — | — | — | — |

Notes:

- **`add=:auto` always resolves to `:ripple`** (it is *not* an adaptive heuristic).
  Cuccaro's one-wire saving is erased by Bennett's copy-out, and its MAJ/UMA chain
  serializes every Toffoli; QCLA has *more* Toffolis than ripple at every width and
  wins only on `O(log W)` Toffoli-depth. Any documentation claiming `:auto` "picks
  Cuccaro when the operand is dead" is stale.
- Ripple is the regression baseline. End-to-end `x + 1` with
  `add=:ripple, fold_constants=true`: i8/i16/i32/i64 `total = 58/114/226/450`,
  `Toffoli = 12/28/60/124` (pinned in `test/test_gate_count_regression.jl`).
- The Cuccaro implementation is the carry-suppressed mod-`2^W` variant (with the
  Cuccaro 2004 §3.5 high-bit optimization), so its counts are `2W-3` Toffoli — *not*
  the paper's carry-out figure of `2n-1`.
- `lower_add_qcla!` returns `W+1` wires (carry-out is the top bit); the binop
  lowering slices `[1:W]` to drop it. The ancilla formula holds only for `W≥4`.

---

## Multiplier selection (`mul=`)

`mul` chooses the lowering for every `mul` LLVM opcode. `_pick_mul_strategy`
(`src/lowering/arith.jl`) resolves it. `n = W`.

| `mul=` | Lowering (`src/`) | Toffoli count | Toffoli-depth | Self-reversing | Paper |
|---|---|---|---|---|---|
| `:shift_add` | `lower_mul!` / `lower_mul_wide!` (`multiplier.jl`) | `O(W²)` | empirically `≈ 6W` (`180` at `W=32`) | no | shift-and-add schoolbook (classic) |
| `:qcla_tree` | `lower_mul_qcla_tree!` (`mul_qcla_tree.jl`) | `12n² − n·log n` (Table III) | `3·log²n + 7·log n + 14` | yes | Sun-Borissov 2026, arXiv:2604.09847 |
| `:auto` | `:shift_add` at `target=:gate_count`; `:qcla_tree` at `target=:depth` | — | — | — | — |

```julia
cs = reversible_compile((x, y) -> x * y, Int32, Int32)               # mul=:auto → shift_add
toffoli_depth(cs)   # => 180

cd = reversible_compile((x, y) -> x * y, Int32, Int32; mul = :qcla_tree)
toffoli_depth(cd)   # => 56
```

Notes:

- **`mul=:karatsuba` was removed (2026-04-27) and now throws `ArgumentError`.**
  It was `1.91–3.49×` worse on Toffoli count than schoolbook at every `W≤64`
  (the `Θ(W^log₂5)` ancilla cost dominated the `Θ(W^log₂3)` Toffoli savings; the
  crossover lies past `W=128`, which the IR extractor cannot lower). `multiplier.jl`
  retains only an explanatory comment.
- `lower_mul_qcla_tree!` returns the full `2W`-bit product and is self-reversing,
  but the binop lowering slices `[1:W]` (mod `2^W`) for an LLVM `mul`, so the
  self-reversing fast path is currently unreachable on that route (the high `W`
  bits are stranded as dirty ancillae).
- Measured `qcla_tree` Toffoli-depth *beats* the paper's Table III formula
  (`< 0.5×`) due to wire-granular parallelism.

---

## Objective and backend (`target=`)

`target` picks the optimization objective and the backend. There is **no
`:circuit` value**.

| `target=` | Effect | `mul=:auto` resolves to | Returns |
|---|---|---|---|
| `:gate_count` (default) | minimize total gates | `:shift_add` | `ReversibleCircuit` |
| `:depth` | minimize Toffoli-depth | `:qcla_tree` | `ReversibleCircuit` |
| `:reversible_vm` | emit BennettVM program | — | `BennettVM.VMProgram` |

- `target=:depth` is the *only* value that promotes `mul=:auto` to `:qcla_tree`
  (`lower()` pre-resolves this in `src/lowering/driver.jl`). `add=:auto` is
  unaffected — it stays `:ripple` under every target.
- **`target=:reversible_vm` is shipped.** It requires `using BennettVM` (the sibling
  repo `../BennettVM.jl`), whose `__init__` registers the VM lowering hook
  (`Bennett.jl` holds `_REVERSIBLE_VM_BACKEND = Ref{Any}(nothing)` until then).
  The call then returns a `BennettVM.VMProgram`; an end-to-end Collatz round-trip
  works today. Without `BennettVM` loaded, the hook is absent.

---

## Compile path (`strategy=`)

The `strategy` kwarg of `reversible_compile` is a `Symbol` selecting *how* the
function is compiled — distinct from the `BennettStrategy` types in the next
section (which are consumed later, at the `bennett()` stage).

| `strategy=` | Path | Applicability |
|---|---|---|
| `:auto` (default) | expression graph, with a cost model that may divert to tabulate | diverts to tabulate iff total input width `≤ 4` **and** the IR contains an `O(W²)` op (`mul`/`udiv`/`sdiv`/`urem`/`srem`) — `src/tabulate.jl` |
| `:expression` | always lower the extracted IR per-opcode | any supported signature |
| `:tabulate` | evaluate `f` on all `2^W` inputs, emit one QROM lookup; skips IR extraction | hard cap: total input width `≤ 16` (`_tabulate_applicable`) |

`:tabulate` produces a self-reversing circuit (it marks the `LoweringResult`
`self_reversing = true`, so `bennett()` skips the copy + uncompute wrap). A
`target=:reversible_vm` compile is never diverted to tabulate.

---

## Space-time schedulers (`BennettStrategy`)

These tag types select the construction algorithm applied to a lowered
`LoweringResult`, trading ancilla space against gate-count/time. They are consumed
by

```julia
bennett(lr::LoweringResult; strategy::BennettStrategy = DefaultStrategy())
```

in `src/bennett_strategies.jl`. **`bennett` and `bennett_direct` are not exported**
— reach them as `Bennett.bennett` or `using Bennett: bennett`. The seven tag types
*are* exported.

| Strategy | Idea | Space / time | Impl (`src/`) | Paper |
|---|---|---|---|---|
| `DefaultStrategy()` | canonical forward + CNOT-copy + reverse | space `n`, time `2n-1` | `_bennett_default` (`bennett_transform.jl`) | Bennett 1973, *Logical Reversibility of Computation*, IBM J. Res. Dev. 17(6):525–532, DOI [10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525) |
| `EagerStrategy()` | gate-level dead-**end** cleanup: uncompute wires never used as a control as soon as they die | reduces peak ancilla vs. default | `_eager_bennett_impl` (`pebble/eager.jl`) | Parent, Roetteler, Svore 2015 (PRS15), *Reversible circuit compilation with space constraints* |
| `ValueEagerStrategy()` | PRS15 Algorithm 2: group/value-level EAGER + Kahn reverse-topological uncompute over the SSA `GateGroup` DAG | reclaims group wires as soon as the DAG allows | `_value_eager_bennett_impl` (`pebble/value_eager.jl`) | PRS15, Algorithm 2 |
| `CheckpointStrategy()` | keep only per-group checkpoints; recompute on demand | peak ≈ `inputs + outputs + Σ checkpoints + max(one group)` | `_checkpoint_bennett_impl` (`pebble/pebbled_groups.jl`) | PRS15 §III.B |
| `PebbledStrategy(max_pebbles)` | Knill 1995 gate-level recursive pebble game | `max_pebbles` pebbles; `min_pebbles(n) = 1 + ⌈log₂ n⌉` | `_pebbled_bennett_impl` (`pebble/pebbling.jl`) | Knill 1995, pebble-game analysis, Theorem 2.1 |
| `PebbledGroupStrategy(max_pebbles)` | group-level pebbling with `WireAllocator` wire reuse | bounded by `max_pebbles` | `_pebbled_group_bennett_impl` (`pebble/pebbled_groups.jl`) | Knill 1995 + PRS15 §III.B |

`PebbledStrategy()` and `PebbledGroupStrategy()` default `max_pebbles = 0`.

### Legacy aliases (exported)

Zero-overhead forwarders retained for pre-1.0 call sites (no `@deprecate`):

| Alias | Equivalent |
|---|---|
| `eager_bennett(lr)` | `bennett(lr, EagerStrategy())` |
| `value_eager_bennett(lr)` | `bennett(lr, ValueEagerStrategy())` |
| `checkpoint_bennett(lr)` | `bennett(lr, CheckpointStrategy())` |
| `pebbled_bennett(lr; max_pebbles=0)` | `bennett(lr, PebbledStrategy(max_pebbles))` |
| `pebbled_group_bennett(lr; max_pebbles=0)` | `bennett(lr, PebbledGroupStrategy(max_pebbles))` |

### Strategy caveats

- **All six strategies honor the self-reversing fast path** (since Bennett-rjk7):
  each runs the same U03 probe (`_validate_self_reversing!`) and returns
  forward-only when `lr.self_reversing` is set.
- **Every non-default strategy refuses branching CFGs.** When a `LoweringResult`
  has `≥ 2` predecessor (`__pred_*`) groups, pebbled/value-eager/checkpoint/
  pebbled-group all fall back to `_bennett_default`, because those groups carry
  empty `input_ssa_vars` and the wire-level cross-dependencies are invisible to the
  dependency DAG. Loop-guard-bearing `LoweringResult`s likewise fall back — only
  `_bennett_default` implements the loop-convergence copy-out.
- `max_pebbles = 0` (the default, or any value `≥ n`) **degrades to full Bennett**,
  not an error.
- Cuccaro in-place adders break pebbling/checkpoint replay (result wires extend
  outside the group's wire range) and force a fallback to full `bennett(lr)`.
- **Bennett 1989** (*Time/Space Trade-Offs for Reversible Computation*, SIAM
  J. Comput. 18(4), DOI [10.1137/0218053](https://doi.org/10.1137/0218053)) is cited
  in the references but **not implemented** — the space-time variants implement
  Knill 1995's analysis of the pebble game, not the 1989 construction. Do not use
  the 1989 DOI for the 1973 construction.
- Meuli 2019 SAT-based pebbling is **not** present: `src/sat_pebbling.jl` and the
  PicoSAT dependency were removed (a modern-SAT replacement is future work).

---

## Reversible memory strategies

Memory accesses (`alloca`/`load`/`store`/GEP) lower to one of five reversible
primitives. **They do not share one dispatcher** — each has a distinct selection
path. `W` = element width, `N` = element count, `L` = table length.

| Strategy | Activates when | Cost per op | Dispatch path (`src/`) | Paper |
|---|---|---|---|---|
| **Shadow** | index is a compile-time constant (any shape) | `3W` CNOT/store, `W` CNOT/load, `0` Toffoli; guarded store `3W` Toffoli | `_pick_alloca_strategy → :shadow` (`lowering/memory.jl`, emit in `shadow_memory.jl`) | shadow memory, Moses–Churavy 2020 (Enzyme) |
| **MUX-EXCH** | dynamic index, shape `(W,N) ∈ _MUX_SHAPES_NW` with `N·W ≤ 64` | branchless `ifelse` chain on one packed `UInt64` (registered `soft_mux_*_NxW` callees) | `_pick_alloca_strategy → :mux_exch_NxW` (`lowering/memory.jl`, callees in `softmem.jl`) | — (branchless in-register exchange) |
| **Shadow-checkpoint** | dynamic index, `N·W > 64` (universal fallback) | `O(N·W)`: per-slot index-equality-guarded shadow stores / per-slot Toffoli-copy loads | `_pick_alloca_strategy → :shadow_checkpoint` (`lowering/memory.jl`) | — (T4 universal fallback) |
| **QROM** | GEP base is a compile-time-constant global, runtime index | `2(L-1)` Toffoli + `O(L·W)` CNOT; **T-count `4(L-1)`, `W`-independent**; self-uncomputing | `lower_var_gep! → _emit_qrom_from_gep! → emit_qrom!` (`lowering/aggregate.jl`, `qrom.jl`) | Babbush, Gidney, Berry, Wiebe, McClean, Paler, Fowler, Neven 2018, arXiv:1805.03662 (§III) |
| **Persistent-DS** | dynamic `n_elems` under `mem=:persistent` | allocates `_state_len_bits(impl)` zero wires (`linear_scan` = `9·64 = 576` bits); `linear_scan` ≈ `414` gates/set, constant in `max_n` | `_pick_alloca_strategy_dynamic_n → :persistent_tree` (`lowering/memory.jl`, `persistent/`) | — (persistent-map tier) |

```julia
# 4-entry constant global table → QROM via the GEP path
sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1]
gate_count(reversible_compile(sbox, UInt8))
#  => (total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

Notes:

- **QROM Toffoli count is `2(L-1)`, not `4(L-1)`.** `4(L-1)` is the *T-count* (the
  `W`-independent figure that matches the Babbush–Gidney bound). The raw Toffoli
  count is pinned in `test/test_qrom.jl` at `{2,6,14,30}` for `L ∈ {2,4,8,16}`.
- `mem=:auto` (default) is byte-identical to the pre-persistent behavior. A
  dynamic-`n` alloca under `mem=:auto` *throws* and hints `mem=:persistent`. All
  four `persistent_impl` arms are wired, but only `hashcons=:none` is supported
  (`:naive`/`:feistel` throw).
- **Feistel hashing (`emit_feistel!`, `feistel.jl`) is never auto-dispatched.** It
  is a standalone reversible bijective-hash primitive (`≈ 4W` Toffoli for the
  default 4 rounds — *not* `8W`; Luby–Rackoff 1988), a building block for
  Feistel-backed dictionaries rather than a `_pick_alloca_strategy` output.
- `persistent_impl` choices: `:linear_scan` (default — the measured winner at all
  scales), `:okasaki` (red-black tree), `:hamt` (Bagwell HAMT), `:cf`
  (Conchon–Filliâtre semi-persistent).

---

## Controlled circuits

`controlled(c)` lifts a compiled circuit to take an explicit control bit, giving
`(ctrl, x, 0) ↦ (ctrl, x, ctrl ? f(x) : 0)` (`src/controlled.jl`). Gate promotion:
`NOT → CNOT`, `CNOT → Toffoli`, `Toffoli →` three Toffolis plus one shared ancilla.

```julia
c  = reversible_compile(x -> x + Int8(1), Int8)
cc = controlled(c)
simulate(cc, true,  Int8(42))   # => 43   (computes f(x))
simulate(cc, false, Int8(42))   # => 0    (off-branch output stays 0, not the input)
```

---

## See also

- [API reference](../reference/api.md) — full signatures for `reversible_compile`,
  `CompileOptions`, and the diagnostics.
- [Architecture guide](../explanation/architecture.md) — the pipeline and the "why" behind
  these choices.
- [Tutorial](../tutorials/first_circuit.md) — learning-by-doing walkthrough.
- [Project README](../../../README.md) — overview and the papers table.
