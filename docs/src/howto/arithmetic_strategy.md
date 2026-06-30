# How to choose adder and multiplier strategies

_Task recipe for tuning the arithmetic primitives Bennett.jl emits — pick `add=`, `mul=`, and `target=` to trade gate count against circuit depth. Assumes you already know how to call `reversible_compile`._

Every `+`, `-`, and `*` in your function is lowered to a concrete reversible
adder or multiplier. Which one is chosen is controlled by three keyword
arguments to `reversible_compile`. The choice applies to **every** matching
operation in the function — it is not per-call-site.

## The recipe

1. **Want the smallest circuit? Do nothing.** The defaults (`add=:auto` →
   ripple, `mul=:auto` → shift-and-add, `target=:gate_count`) minimise total
   Toffoli count and ancilla budget. This is the right choice for simulation
   and for NISQ-scale resource estimates.
2. **Want the shallowest circuit (FTQC / fault-tolerant)? Set `target=:depth`,
   or name a depth-optimal primitive directly.** `target=:depth` flips
   `mul=:auto` to the Sun-Borissov QCLA-tree multiplier. For addition, ask for
   `add=:qcla` explicitly. Depth (and hence T-depth, since
   `t_depth = toffoli_depth × k`) drops at the cost of more total gates and
   ancillae.
3. **Want a specific primitive? Name it.** `add=:ripple|:cuccaro|:qcla`,
   `mul=:shift_add|:qcla_tree`. Explicit choices bypass the `:auto` heuristic
   entirely.

```julia
using Bennett

# Default — gate-count optimal.
c = reversible_compile(x -> x + Int8(1), Int8)
gate_count(c)            # (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
toffoli_depth(c)         # 12
verify_reversibility(c)  # true
```

`gate_count` returns a `NamedTuple` `(total, NOT, CNOT, Toffoli)`, not an
`Int`. `toffoli_depth`, `t_count`, `ancilla_count`, and `depth` each return an
`Int`. See [`../reference/api.md`](../reference/api.md) for the full metric set.

## Adder dispatch (`add=`)

`add ∈ {:auto, :ripple, :cuccaro, :qcla}`, validated in
`src/lowering/driver.jl`; the heuristic lives in `_pick_add_strategy`
(`src/lowering/arith.jl`).

| `add=` | Primitive (file) | Toffoli count | Toffoli-depth | Ancilla | Source |
| --- | --- | --- | --- | --- | --- |
| `:ripple` | `lower_add!` (`src/adder.jl`) | `2(W−1)` | `O(W)` — serial carry chain | `W` | Textbook ripple-carry full adder |
| `:cuccaro` | `lower_add_cuccaro!` (`src/adder.jl`) | `2W−3` | `O(W)` | `1` | Cuccaro et al. 2004, in-place mod-2^W variant (§3.5 high-bit opt) |
| `:qcla` | `lower_add_qcla!` (`src/qcla.jl`) | `> 2(W−1)` | `O(log W)` | `≈ W` | Draper–Kutin–Rains–Svore 2004, [arXiv:quant-ph/0406142](https://arxiv.org/abs/quant-ph/0406142) |
| `:auto` | → `:ripple`, always | — | — | — | Bennett-spa8 / U27 |

Notes:

- **`add=:auto` always resolves to `:ripple`.** It is *not* an adaptive
  heuristic — there is no "Cuccaro when the operand is dead" path (that was
  removed in Bennett-spa8 / U27). Cuccaro's one-wire in-place saving is erased
  by Bennett's copy-out pass, and its MAJ/UMA chain serialises every Toffoli,
  so it ships strictly worse depth for no net wire win.
- **QCLA has *more* Toffolis than ripple at every width.** Its only advantage
  is `O(log W)` Toffoli-depth versus ripple's `O(W)`. Reach for it only when
  depth is the objective.

```julia
# Depth-optimal addition: ask for QCLA explicitly.
c = reversible_compile((x, y) -> x + y, Int32, Int32; add=:qcla)
verify_reversibility(c)  # true
```

## Multiplier dispatch (`mul=`)

`mul ∈ {:auto, :shift_add, :qcla_tree}`, validated in
`src/lowering/driver.jl`; the heuristic lives in `_pick_mul_strategy`
(`src/lowering/arith.jl`).

| `mul=` | Primitive (file) | Toffoli count | Toffoli-depth | Source |
| --- | --- | --- | --- | --- |
| `:shift_add` | `lower_mul_wide!` (`src/multiplier.jl`) | `O(W²)` | `O(W)` (empirical) | Schoolbook shift-and-add |
| `:qcla_tree` | `lower_mul_qcla_tree!` (`src/mul_qcla_tree.jl`) | `≈ 5×` shift-add | `O(log² W)` | Sun–Borissov 2026, [arXiv:2604.09847](https://arxiv.org/abs/2604.09847); self-reversing |
| `:auto` | → `:shift_add` (`target=:gate_count`) / `:qcla_tree` (`target=:depth`) | — | — | `_pick_mul_strategy` |
| `:karatsuba` | **removed — throws `ArgumentError`** | — | — | Bennett-tbm6 (2026-04-27) |

## Recipe: depth matters (FTQC)

When you are targeting a fault-tolerant architecture, T-depth — not total gate
count — is the cost that matters, and `toffoli_depth` is the proxy for it
(each Toffoli decomposes to a fixed-depth T-gadget). The QCLA-tree multiplier
collapses the depth dramatically. On `Int32 × Int32`:

```julia
square = (x, y) -> x * y

c_default = reversible_compile(square, Int32, Int32)                  # mul=:shift_add
c_tree    = reversible_compile(square, Int32, Int32; mul=:qcla_tree)

toffoli_depth(c_default)  # 180
toffoli_depth(c_tree)     # 56
```

That is a **3.2× depth reduction** (180 → 56) for the same product. The trade
is more total Toffoli gates and more ancillae — exactly the bargain you want
when error-corrected logical depth dominates the resource bill.

You do not have to name the multiplier by hand. Setting `target=:depth`
flips `mul=:auto` from shift-and-add to `qcla_tree` (pre-resolved in
`src/lowering/driver.jl`), so the depth-optimal multiplier is selected
automatically:

```julia
# target=:depth promotes mul=:auto → :qcla_tree, producing the same
# 56-Toffoli-depth circuit as mul=:qcla_tree above.
c = reversible_compile((x, y) -> x * y, Int32, Int32; target=:depth)
verify_reversibility(c)  # true
```

`target ∈ {:gate_count (default), :depth, :reversible_vm}`. Only `:gate_count`
and `:depth` affect arithmetic-strategy selection; `:reversible_vm` re-routes
the whole compile to the BennettVM backend (requires `using BennettVM`) and is
unrelated to the adder/multiplier knobs.

## Recipe: gate count matters (the default)

Keep the defaults. For `add=:ripple, fold_constants=true` (the default path)
the per-width baselines are pinned as regression tests
(`test/test_gate_count_regression.jl`): `Int8` `x+1` is 58 total gates with 12
Toffolis, doubling by `total(2W) = 2·total(W) − 2` and `T(2W) = 2·T(W) + 4`.
A larger worked example:

```julia
f(x::Int8) = x * x + Int8(3) * x + Int8(1)
c = reversible_compile(f, Int8)
simulate(c, Int8(5))     # 41   (== 25 + 15 + 1)
gate_count(c)            # (total = 482, NOT = 14, CNOT = 300, Toffoli = 168)
verify_reversibility(c)  # true
```

## Gotchas

- **`mul=:karatsuba` no longer exists.** It was removed on 2026-04-27
  (Bennett-tbm6): the recursive multiplier was 1.91–3.49× *worse* on Toffoli
  count than schoolbook at every width Bennett.jl can lower (`W ≤ 64`), because
  its `Θ(W^log₂5)` ancilla cost swamped the `Θ(W^log₂3)` gate saving. Passing
  it now raises an error:

  ```julia
  reversible_compile((x, y) -> x * y, Int32, Int32; mul=:karatsuba)
  # ERROR: ArgumentError: lower: unknown mul strategy :karatsuba; supported:
  #   :auto, :shift_add, :qcla_tree (Bennett-tbm6: :karatsuba removed 2026-04-27)
  ```

- **The strategy is global to the function.** `add=`/`mul=` pick one primitive
  for *all* adds / muls in the compiled function. There is no per-operation
  override.

- **These knobs only touch `+`, `-`, `*`.** Division and remainder route
  through a fixed 64-iteration restoring-division callee (`src/divider.jl`),
  unaffected by `add=`/`mul=`. Memory operations have their own dispatcher
  (`mem=`, `persistent_impl=`); see the memory how-to.

- **`add=:auto` is ripple, `mul=:auto` is shift-add.** If you read older notes
  claiming `:auto` adaptively picks Cuccaro or Karatsuba, they are stale.

## See also

- [`../reference/api.md`](../reference/api.md) — full `reversible_compile`
  keyword reference and the `CompileOptions` struct.
- [`../../../README.md`](../../../README.md) — project overview and the gate
  primitives.
- Bennett 1973, "Logical Reversibility of Computation", *IBM J. Res. Dev.*
  17(6), [doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525) — the
  forward + copy + reverse construction these strategies feed into.
