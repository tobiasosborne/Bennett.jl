# How to compile mutable state into a reversible circuit

*For when your Julia function reads and writes arrays, refs, or lookup tables — and you need the resulting reversible circuit to leave every ancilla at zero. This page is a recipe: pick the row that matches your access pattern, then read the example.*

Bennett.jl has no `store`/`load` gate. Mutable memory is lowered to one of several
reversible *strategies*, each a CNOT/Toffoli pattern that preserves the input and
returns its scratch wires to zero. You do not select a strategy by hand: the lowerer
inspects each memory access — its element width `W`, slot count `N`, and whether the
index is a compile-time constant — and dispatches to the cheapest correct lowering.
Your job is to write the access pattern that lands on the strategy you want, and to
know when you have left the circuit path entirely.

## The recipe

| Your access pattern | Strategy | Dispatched by |
|---|---|---|
| `Ref`, or an array with a **static / constant** index | **shadow** | `_pick_alloca_strategy` → `:shadow` |
| Array with a **dynamic** index, small footprint (`N·W ≤ 64`) | **MUX-EXCH** | `_pick_alloca_strategy` → `:mux_exch_NxW` |
| Array with a dynamic index, `N·W > 64` | **shadow-checkpoint** | `_pick_alloca_strategy` → `:shadow_checkpoint` |
| A **compile-time-constant** lookup table indexed at runtime | **QROM** | `lower_var_gep!` on a const-global |
| **Large / unbounded** (dynamic `N`) map-shaped state | **persistent** | `_pick_alloca_strategy_dynamic_n` under `mem=:persistent` |

Note the **different dispatch paths**: only shadow, MUX-EXCH, and shadow-checkpoint
come out of `_pick_alloca_strategy` (`src/lowering/memory.jl`). QROM is a *separate*
path — it fires from `lower_var_gep!` in `src/lowering/aggregate.jl` when a GEP's base
is a compile-time-constant global table. The persistent tier is a *third* path,
`_pick_alloca_strategy_dynamic_n`, reached only when you opt in with `mem=:persistent`.
A fifth primitive, Feistel hashing (`emit_feistel!`), exists but is **never
auto-dispatched** — it is a standalone building block for future hash-backed
dictionaries.

## Ref and static-index arrays → shadow

A `Ref`, or any array access whose index is a compile-time constant, lowers to the
**shadow** strategy: a direct CNOT pattern adapted from Enzyme's shadow memory
(Moses–Churavy 2020). A store checkpoints the old primal onto a fresh tape slot and
writes the new value; Bennett's reverse pass restores `tape = 0` and `primal = old`.

- **Store:** `3·W` CNOT, 0 Toffoli (`emit_shadow_store!`, `src/shadow_memory.jl`)
- **Load:** `W` CNOT, 0 Toffoli (`emit_shadow_load!`)
- **Predicate-guarded store** (inside a branch): `3·W` Toffoli, 0 CNOT
  (`emit_shadow_store_guarded!`)

Because the index is known at compile time, no MUX tree is needed — shadow is the
cheapest possible lowering and is always chosen for constant indices regardless of
shape.

## Dynamic small index → MUX-EXCH

When the index is computed at runtime but the whole array fits in a single packed
`UInt64` (`N·W ≤ 64`), the access lowers to a branchless **MUX-EXCH** callee
(`soft_mux_load_NxW` / `soft_mux_store_NxW`, `src/softmem.jl`). The callee is a plain
branchless Julia function — an `ifelse` chain selecting slot `idx` — so the standard
extract → lower → bennett pipeline reversibilises it like any other call.

The supported shapes are the single source of truth `_MUX_SHAPES_NW`
(`src/lowering/memory.jl`):

```
(2,8) (4,8) (8,8) (2,16) (4,16) (2,32) (3,8) (5,8) (6,8) (7,8) (3,16)
```

— every `(N, W)` with `N·W ≤ 64`. Each shape auto-generates load/store/guarded-store
callees and dispatch-table entries. Cost is `O(N·W)` — one `ifelse` per output bit per
index level — so MUX-EXCH is the right choice only at this small footprint; beyond it,
shadow-checkpoint takes over.

## const lookup table → QROM

A read-only table baked into the program at compile time, indexed by a runtime value,
is the QROM sweet spot. QROM (Babbush–Gidney 2018, arXiv:1805.03662) builds a complete
binary AND-tree of unary iteration over the `log₂(L)` index bits, fans the table data
out through CNOTs, then reverses the tree to uncompute every flag — self-clean, using
`O(log L)` ancillae that return to zero. Crucially its T-count is **independent of `W`**.

Here is the verified S-box example. The table has four `UInt8` entries; the index is
the runtime low two bits of `x`:

```julia
using Bennett

sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1]

c = reversible_compile(sbox, UInt8)

gate_count(c)            # => (total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
verify_reversibility(c)  # => true
simulate(c, UInt8(2))    # => 119   (0x77, the third table entry)
```

`gate_count` returns a `NamedTuple`, not an `Int`. The raw QROM kernel for an `L`-entry
table is `2(L-1)` Toffoli; here `L = 4` contributes 6, and the remaining 2 Toffoli come
from materialising the `x & 0x3` index. The compiled function's `t_count` is `7 ×
Toffoli = 56` under Bennett's default Toffoli-to-7T decomposition — distinct from the
paper's `4(L-1)` measurement-based T-count, which is the `W`-independent figure QROM is
famous for.

A table that is not a power of two is zero-padded to the next power of two before the
QROM kernel runs (handled in `_emit_qrom_from_gep!`); a fully constant index
short-circuits to direct `NOT`-gate materialisation.

## large / unbounded → mem=:persistent

When the slot count `N` is not known at compile time (a `Vector` whose size depends on
runtime data, used as a map), the static strategies do not apply. Under the default
`mem=:auto` this case **fails fast** — the dynamic-`N` alloca arm refuses to guess and
throws, pointing you at the opt-in:

```julia
# dynamic-N alloca under mem=:auto throws ArgumentError:
#   "... Re-run reversible_compile(f, ...; mem=:persistent) to enable it."
```

Opt in with `mem=:persistent`, and the access routes through the persistent-map tier
(`src/persistent/`). The backing implementation is chosen by `persistent_impl`:

```julia
reversible_compile(f, (Int8, Int8);
                   mem=:persistent,
                   persistent_impl=:linear_scan)   # the default — and the winner
```

`persistent_impl ∈ {:linear_scan (default), :okasaki, :hamt, :cf}`. The trivial
`:linear_scan` — a fixed-size branchless full scan — wins at every measured scale: its
per-set cost is **constant in `max_n`** at ~414 gates/set (414,028 total gates at
`max_n = 1000`). The "clever" structures lose under reversible compilation:
`:okasaki` speculatively computes all four red-black balance cases per insert,
`:hamt`'s popcount alone (~1,454 gates) exceeds linear-scan's whole per-set floor, and
`:cf` is `O(N)` per set because Bennett cannot prove only one of its growing Diff writes
fires. See the persistent-DS scaling writeup for the full cost model. (`:hamt`
additionally requires `optimize=true`, which `src/extract` discourages; `hashcons` is
accepted as `:none`/`:naive`/`:feistel` but only `:none` is wired.)

## Cost per strategy

| Strategy | Per store | Per load | Notes |
|---|---|---|---|
| **shadow** | `3·W` CNOT, 0 Toffoli | `W` CNOT, 0 Toffoli | guarded store: `3·W` Toffoli; `src/shadow_memory.jl` |
| **MUX-EXCH** | `O(N·W)` | `O(N·W)` | `N·W ≤ 64`, branchless `ifelse` callee; `src/softmem.jl` |
| **shadow-checkpoint** | `O(N·W)` | `O(N·W)` | universal fallback for `N·W > 64` |
| **QROM** | — (read-only) | `2(L-1)` Toffoli + `O(L·W)` CNOT | T-count `4(L-1)`, **`W`-independent**; `src/qrom.jl` |
| **persistent (linear_scan)** | ~414 gates/set, **constant in `max_n`** | full branchless scan | `mem=:persistent`; `src/persistent/linear_scan.jl` |
| **Feistel** (not auto-dispatched) | ~`4·W` Toffoli per eval | — | `emit_feistel!`, `src/feistel.jl`; standalone primitive |

Citations: shadow ← Enzyme / Moses–Churavy 2020; QROM ← Babbush–Gidney 2018
(arXiv:1805.03662); Feistel ← Luby–Rackoff 1988. Verify any compiled circuit with
`verify_reversibility(c; n_tests=100)` — "runs without error" is never a passing test;
all ancillae must return to zero.

## When the circuit path rejects you: `Dict` and runtime-sized arrays

A `Dict`, or a runtime-sized array that does not match the dynamic-`N` map pattern the
persistent tier recognises, is **rejected on the circuit path**. There is no reversible
circuit for arbitrary heap-shaped, runtime-allocated state at fixed gate count.

For these, switch to the **reversible VM** backend, which models a heap and executes
reversibly at runtime rather than emitting a fixed circuit:

```julia
using BennettVM   # registers the lower_vm backend

prog = reversible_compile(f, arg_types; target=:reversible_vm)  # => BennettVM.VMProgram
```

`target ∈ {:gate_count (default), :depth, :reversible_vm}` — there is no `:circuit`
value. The VM path is shipped (end-to-end Collatz round-trips today); it lives in the
sibling repo `BennettVM.jl` and returns a `BennettVM.VMProgram`.

## See also

- [Compile-options reference](../reference/api.md) — the full `mem`,
  `persistent_impl`, `hashcons`, and `target` value sets.
- Source of truth: `src/lowering/memory.jl` (dispatchers), `src/qrom.jl`,
  `src/shadow_memory.jl`, `src/softmem.jl`, `src/persistent/`.
- [Project README](../../../README.md) — strategy overview and benchmark headlines.
