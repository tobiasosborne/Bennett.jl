# ---- Shadow memory: universal reversible store/load primitive ----
#
# Per docs/memory/shadow_design.md (T3b.1). Adapts Enzyme's shadow-memory
# pattern to the reversibility setting: instead of linear-accumulating
# derivatives on a shadow register, we checkpoint the primal's previous
# value onto a tape slot and restore it on Bennett's reverse pass.
#
# These primitives are the UNIVERSAL FALLBACK — applicable to any write
# when T1b (MUX EXCH) / T1c (QROM) / T2b (linear) / T3a (Feistel) don't
# fit. Cost: 3W CNOTs per store, W CNOTs per load. Zero Toffolis.
#
# Protocol per store (primal ← val, tape ← old primal):
#   1. CNOT primal[i] → tape[i]   (tape = old primal)
#   2. CNOT tape[i]   → primal[i] (primal = primal XOR tape = 0, since
#                                  tape currently equals primal)
#   3. CNOT val[i]    → primal[i] (primal = val)
#
# Bennett reverse unwinds this to primal = old, tape = 0.
#
# Tape slots must be pre-allocated by the caller (one slot per store
# instance) — this keeps the primitive pure gate-emission with no hidden
# state. The universal dispatcher (T3b.3) or SAT pebbler decides slot
# allocation strategy.

"""
    emit_shadow_store!(gates, wa, primal, tape_slot, val, W) -> Nothing

Reversibly write `val` into `primal`, saving the old primal value onto the
tape slot for later uncomputation. After this call:
  - `primal` holds `val`
  - `tape_slot` holds the old primal value

Emits `3·W` CNOT gates, zero Toffolis. Both `primal` and `tape_slot` must
have length `W`. Caller is responsible for ensuring `tape_slot` wires
start at zero (they will after Bennett reverse — it's the caller's
invariant to allocate a fresh slot per store).
"""
function emit_shadow_store!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                            primal::Vector{Int}, tape_slot::Vector{Int},
                            val::Vector{Int}, W::Int)
    length(primal)    == W || error("emit_shadow_store!: primal has $(length(primal)) wires, W=$W")
    length(tape_slot) == W || error("emit_shadow_store!: tape_slot has $(length(tape_slot)) wires, W=$W")
    length(val)       == W || error("emit_shadow_store!: val has $(length(val)) wires, W=$W")

    for i in 1:W
        push!(gates, CNOTGate(primal[i], tape_slot[i]))
    end
    for i in 1:W
        push!(gates, CNOTGate(tape_slot[i], primal[i]))
    end
    for i in 1:W
        push!(gates, CNOTGate(val[i], primal[i]))
    end
    return nothing
end

"""
    emit_shadow_load!(gates, wa, primal, W) -> Vector{Int}

Reversibly read `primal` into fresh output wires. Emits `W` CNOT gates,
zero Toffolis. Returns the W output wires (each a CNOT-copy of the
corresponding primal wire).

Shadow-memory loads require no tape slot: the load is a pure copy and
Bennett's reverse undoes it naturally.
"""
function emit_shadow_load!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                           primal::Vector{Int}, W::Int)
    length(primal) == W || error("emit_shadow_load!: primal has $(length(primal)) wires, W=$W")
    out = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(primal[i], out[i]))
    end
    return out
end

"""
    emit_shadow_store_guarded!(gates, wa, primal, tape_slot, val, W, pred_wire) -> Nothing

Bennett-cc0 M2c — conditional shadow store. Same semantic as
`emit_shadow_store!` when `pred_wire = 1`; no-op (identity on primal and
tape_slot) when `pred_wire = 0`.

Each CNOT of the 3·W-CNOT pattern becomes a Toffoli(pred_wire, ctrl, tgt).
Bennett's reverse is self-inverse per-gate: `pred_wire` is the block
predicate (written once during block prologue, read-only thereafter), so
the reverse pass sees the same guard value and unwinds correctly on both
paths (pred=0 reverse is also no-op; pred=1 reverse matches the
unguarded inverse).

Cost: 3·W Toffoli, 0 CNOT. Caller must pass `pred_wire` as a single wire
holding the current block's path predicate (lookup: `ctx.block_pred[label][1]`
for single-wire path predicates; multi-wire predicates would need AND-reduction
before calling this primitive).

See `emit_shadow_store!` for the unguarded base case.
"""
function emit_shadow_store_guarded!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                    primal::Vector{Int}, tape_slot::Vector{Int},
                                    val::Vector{Int}, W::Int, pred_wire::Int)
    # Bennett-6e0i / U129: callee-internal width invariants — these are
    # programming-error checks (caller-side bug), not user-facing
    # diagnostics. @assert's `||` semantics are identical to the prior
    # `cond || error(...)` form (lazy message), but the @assert keyword
    # signals INVARIANT to readers vs user-input validation.
    @assert length(primal)    == W "emit_shadow_store_guarded!: primal has $(length(primal)) wires, W=$W"
    @assert length(tape_slot) == W "emit_shadow_store_guarded!: tape_slot has $(length(tape_slot)) wires, W=$W"
    @assert length(val)       == W "emit_shadow_store_guarded!: val has $(length(val)) wires, W=$W"

    for i in 1:W
        push!(gates, ToffoliGate(pred_wire, primal[i], tape_slot[i]))
    end
    for i in 1:W
        push!(gates, ToffoliGate(pred_wire, tape_slot[i], primal[i]))
    end
    for i in 1:W
        push!(gates, ToffoliGate(pred_wire, val[i], primal[i]))
    end
    return nothing
end
