"""
Bennett-i2ca / U55 — strategy dispatch for the six existing variants.

The pre-i2ca codebase exposed five `*_bennett` entry points
(`eager_bennett`, `value_eager_bennett`, `pebbled_bennett`,
`pebbled_group_bennett`, `checkpoint_bennett`) plus the canonical
`bennett` and the precondition-guarded `bennett_direct`. They duplicated
the Phase 1/2/3 scaffolding and were untestable orthogonally.

This file unifies them under a single `bennett(lr; strategy=...)` API
backed by `abstract type BennettStrategy`. Each variant's body lives in
its own file under `src/pebble/` (or in `src/bennett_transform.jl` for
the default), renamed to `_<variant>_impl` and reached via multiple
dispatch on the strategy singleton/struct. The five legacy names are
kept as zero-overhead forwarders.

`bennett_direct(lr)` is NOT a strategy — it's a precondition check that
asserts `lr.self_reversing == true` then delegates. It stays in
`bennett_transform.jl`.

Loading order in `src/Bennett.jl`:
  bennett_transform.jl  (defines `_bennett_default`, helpers)
  ...
  pebble/eager.jl       (defines `_eager_bennett_impl`)
  pebble/value_eager.jl (defines `_value_eager_bennett_impl`)
  pebble/pebbling.jl    (defines `_pebbled_bennett_impl`)
  pebble/pebbled_groups.jl (defines `_pebbled_group_bennett_impl`,
                            `_checkpoint_bennett_impl`)
  bennett_strategies.jl ← this file: structs + dispatch + forwarders
"""

# ---- abstract type + concrete strategies ------------------------------------

"""
    abstract type BennettStrategy end

Tag type for the `bennett(lr; strategy=...)` dispatch. Concrete
subtypes select alternate Bennett-construction algorithms.

Concrete types: `DefaultStrategy`, `EagerStrategy`, `ValueEagerStrategy`,
`CheckpointStrategy`, `PebbledStrategy`, `PebbledGroupStrategy`.
"""
abstract type BennettStrategy end

"""Canonical forward + CNOT-copy + uncompute. The `bennett(lr)` body."""
struct DefaultStrategy <: BennettStrategy end

"""Gate-level dead-end EAGER cleanup. See `src/pebble/eager.jl`."""
struct EagerStrategy <: BennettStrategy end

"""Group-level value EAGER + Kahn topological reverse. See `src/pebble/value_eager.jl`."""
struct ValueEagerStrategy <: BennettStrategy end

"""Per-group checkpoint-and-free. See `src/pebble/pebbled_groups.jl`."""
struct CheckpointStrategy <: BennettStrategy end

"""
    PebbledStrategy(max_pebbles::Int=0)

Knill 1995 gate-level recursive pebbling. `max_pebbles=0` falls back to
full Bennett (matching the legacy `pebbled_bennett(lr; max_pebbles=0)`
default). See `src/pebble/pebbling.jl`.
"""
struct PebbledStrategy <: BennettStrategy
    max_pebbles::Int
end
PebbledStrategy() = PebbledStrategy(0)

"""
    PebbledGroupStrategy(max_pebbles::Int=0)

Group-level pebbling with wire reuse. `max_pebbles=0` falls through to
the preferred path (`checkpoint_bennett` if wire ranges are populated,
else full Bennett). See `src/pebble/pebbled_groups.jl`.
"""
struct PebbledGroupStrategy <: BennettStrategy
    max_pebbles::Int
end
PebbledGroupStrategy() = PebbledGroupStrategy(0)

# ---- public dispatch --------------------------------------------------------

"""
    bennett(lr::LoweringResult; strategy::BennettStrategy=DefaultStrategy())

Forward to the 2-arg multiple-dispatch form. Adding new strategies is a
matter of (a) adding a `BennettStrategy` subtype and (b) defining
`bennett(lr, ::NewStrategy)`.
"""
bennett(lr::LoweringResult; strategy::BennettStrategy=DefaultStrategy()) =
    bennett(lr, strategy)

bennett(lr::LoweringResult, ::DefaultStrategy)        = _bennett_default(lr)
bennett(lr::LoweringResult, ::EagerStrategy)          = _eager_bennett_impl(lr)
bennett(lr::LoweringResult, ::ValueEagerStrategy)     = _value_eager_bennett_impl(lr)
bennett(lr::LoweringResult, ::CheckpointStrategy)     = _checkpoint_bennett_impl(lr)
bennett(lr::LoweringResult, s::PebbledStrategy)       = _pebbled_bennett_impl(lr; max_pebbles=s.max_pebbles)
bennett(lr::LoweringResult, s::PebbledGroupStrategy)  = _pebbled_group_bennett_impl(lr; max_pebbles=s.max_pebbles)

# ---- legacy aliases (Bennett-i2ca / U55) ------------------------------------
#
# Plain forwarders, no `@deprecate`. Rationale (per i2ca's 3+1 design):
#   - No external consumers exist (Bennett.jl is pre-1.0).
#   - `@deprecate` would emit a depwarn from every pebbling test file
#     (test_pebbled_space.jl, test_eager_bennett.jl, ...) on every run.
#   - Future deprecation is a one-line edit per forwarder when there's
#     an actual 1.0 boundary to enforce against.

eager_bennett(lr::LoweringResult)            = bennett(lr, EagerStrategy())
value_eager_bennett(lr::LoweringResult)      = bennett(lr, ValueEagerStrategy())
checkpoint_bennett(lr::LoweringResult)       = bennett(lr, CheckpointStrategy())
pebbled_bennett(lr::LoweringResult; max_pebbles::Int=0) =
    bennett(lr, PebbledStrategy(max_pebbles))
pebbled_group_bennett(lr::LoweringResult; max_pebbles::Int=0) =
    bennett(lr, PebbledGroupStrategy(max_pebbles))
