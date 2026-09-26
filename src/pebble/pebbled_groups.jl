"""
Group-level pebbled Bennett construction with wire reuse.

Applies Knill's recursive checkpointing at the GateGroup level. Each group
is a pebble unit. When a group is reversed (un-pebbled), its wires return
to zero and are freed back to the WireAllocator for reuse.

Reference: Knill 1995 Theorem 2.1, PRS15 Section III.B (ancilla heap).
"""

# ---- gate remapping ----

function _remap_wire(w::Int, wmap::Dict{Int,Int}, input_wire_set::Set{Int})
    haskey(wmap, w) && return wmap[w]
    w in input_wire_set && return w  # function inputs are identity-mapped
    throw(AssertionError("_remap_wire: unmapped wire $w in gate remapping — not in wmap and not a function input. Possible corruption from freed group wires."))
end

_remap_gate_wmap(g::NOTGate, wmap::Dict{Int,Int}, iws::Set{Int}) =
    NOTGate(_remap_wire(g.target, wmap, iws))

_remap_gate_wmap(g::CNOTGate, wmap::Dict{Int,Int}, iws::Set{Int}) =
    CNOTGate(_remap_wire(g.control, wmap, iws),
             _remap_wire(g.target, wmap, iws))

_remap_gate_wmap(g::ToffoliGate, wmap::Dict{Int,Int}, iws::Set{Int}) =
    ToffoliGate(_remap_wire(g.control1, wmap, iws),
                _remap_wire(g.control2, wmap, iws),
                _remap_wire(g.target, wmap, iws))

# ---- pebble state tracking ----

struct ActivePebble
    # Current location of the SSA result, in the SAME logical bit order (and
    # with the same multiplicity) as the group's original `result_wires`.
    # May contain duplicates; never freed directly (Bennett-uhk3).
    result_wires::Vector{Int}
    # Every wire freshly allocated for this replay, each exactly once
    # (results AND scratch). This — not `result_wires` — is what
    # `_replay_reverse!` returns to the allocator.
    owned_wires::Vector{Int}
    wmap::Dict{Int,Int}          # wire remap used during forward
end

# ---- core operations: forward and reverse a group ----

function _replay_forward!(result::Vector{ReversibleGate},
                          group::GateGroup,
                          gates::Vector{ReversibleGate},
                          wa::WireAllocator,
                          live_map::Dict{Symbol, ActivePebble},
                          input_wire_set::Set{Int},
                          orig_results::Dict{Symbol, Vector{Int}})
    wmap = Dict{Int,Int}()

    # (a) Map dependency wires: original result of each dep → current location
    for dep_name in group.input_ssa_vars
        if haskey(live_map, dep_name)
            pebble = live_map[dep_name]
            orig = orig_results[dep_name]
            for (i, old_w) in enumerate(orig)
                if i <= length(pebble.result_wires)
                    wmap[old_w] = pebble.result_wires[i]
                end
            end
        end
        # Function inputs: identity mapping via get(wmap, w, w) in _remap_gate_wmap
    end

    # (b) Allocate fresh wires for ALL wires this group owns.
    #     wire_start:wire_end covers every wire allocated during lowering:
    #     result wires, carries, partial products, zero-padding, constants.
    n_group_wires = group.wire_end - group.wire_start + 1
    owned = Int[]
    if n_group_wires > 0
        owned = allocate!(wa, n_group_wires)
        for (i, old_w) in enumerate(group.wire_start:group.wire_end)
            wmap[old_w] = owned[i]
        end
    end

    # Bennett-uhk3: map `result_wires` entry-by-entry, preserving its logical
    # bit order and any duplicated positions. Downstream consumers (checkpoint
    # copy, dependency wmap in (a), `_emit_copy_gates!`) zip this vector with
    # the ORIGINAL `group.result_wires`, so it must be position-aligned. The
    # pre-fix code rebuilt it via `Set(result_wires)` + an ascending walk of
    # `wire_start:wire_end`, silently permuting e.g. `[3,2]` into `[2,3]`.
    # In-range entries map to their fresh wire; an out-of-range (in-place,
    # e.g. Cuccaro) entry maps via the dependency wmap from (a) or is a
    # function input (identity) — `_remap_wire` fails loud otherwise.
    new_result = Int[_remap_wire(old_w, wmap, input_wire_set)
                     for old_w in group.result_wires]

    # Emit remapped gates
    for gi in group.gate_start:group.gate_end
        push!(result, _remap_gate_wmap(gates[gi], wmap, input_wire_set))
    end

    # Record pebble
    live_map[group.ssa_name] = ActivePebble(new_result, owned, wmap)
end

function _replay_reverse!(result::Vector{ReversibleGate},
                          group::GateGroup,
                          gates::Vector{ReversibleGate},
                          wa::WireAllocator,
                          live_map::Dict{Symbol, ActivePebble},
                          input_wire_set::Set{Int})
    pebble = live_map[group.ssa_name]

    # Emit reverse gates using the SAME wire map from forward
    for gi in group.gate_end:-1:group.gate_start
        push!(result, _remap_gate_wmap(gates[gi], pebble.wmap, input_wire_set))
    end

    # All wires this replay allocated are now zero — free each exactly once.
    # Bennett-uhk3: free `owned_wires`, never `result_wires` (which may hold
    # duplicate positions or non-owned in-place/input wires).
    free!(wa, pebble.owned_wires)

    delete!(live_map, group.ssa_name)
end

# ---- recursive pebbling engine ----

function _pebble_groups!(result::Vector{ReversibleGate},
                         groups::Vector{GateGroup},
                         gates::Vector{ReversibleGate},
                         wa::WireAllocator,
                         live_map::Dict{Symbol, ActivePebble},
                         input_wire_set::Set{Int},
                         orig_results::Dict{Symbol, Vector{Int}},
                         output_wires::Vector{Int},
                         copy_wires::Vector{Int},
                         lo::Int, hi::Int, s::Int,
                         is_outermost::Bool)
    n = hi - lo + 1
    n <= 0 && return

    # Base case: enough pebbles — full Bennett on this segment
    if n <= s
        for i in lo:hi
            _replay_forward!(result, groups[i], gates, wa, live_map,
                            input_wire_set, orig_results)
        end

        # Insert copy gates at the outermost end
        if is_outermost && hi == length(groups)
            _emit_copy_gates!(result, output_wires, copy_wires,
                              live_map, orig_results)
        end

        for i in hi:-1:lo
            _replay_reverse!(result, groups[i], gates, wa, live_map, input_wire_set)
        end
        return
    end

    s <= 1 && throw(ArgumentError("pebbled_group_bennett: insufficient pebbles — need at least $(min_pebbles(n)) for $n groups, have $s"))

    m = knill_split_point(n, s)
    mid = lo + m - 1

    # Step 1: Forward groups lo..mid (place m pebbles)
    for i in lo:mid
        _replay_forward!(result, groups[i], gates, wa, live_map,
                        input_wire_set, orig_results)
    end

    # Step 2: Recursively process mid+1..hi with s-1 pebbles
    includes_end = is_outermost && (hi == length(groups))
    _pebble_groups!(result, groups, gates, wa, live_map,
                    input_wire_set, orig_results,
                    output_wires, copy_wires,
                    mid + 1, hi, s - 1, includes_end)

    # Step 3: Reverse groups mid:-1:lo (free wires for reuse)
    for i in mid:-1:lo
        _replay_reverse!(result, groups[i], gates, wa, live_map, input_wire_set)
    end
end

# ---- copy gate emission ----

function _emit_copy_gates!(result::Vector{ReversibleGate},
                           output_wires::Vector{Int},
                           copy_wires::Vector{Int},
                           live_map::Dict{Symbol, ActivePebble},
                           orig_results::Dict{Symbol, Vector{Int}})
    # Build mapping: original wire → current wire
    wire_current = Dict{Int,Int}()
    for (name, pebble) in live_map
        orig = orig_results[name]
        for (i, old_w) in enumerate(orig)
            if i <= length(pebble.result_wires)
                wire_current[old_w] = pebble.result_wires[i]
            end
        end
    end

    for (j, orig_w) in enumerate(output_wires)
        src = get(wire_current, orig_w, orig_w)
        push!(result, CNOTGate(src, copy_wires[j]))
    end
end

# ---- public entry point ----

"""
    _pebbled_group_bennett_impl(lr::LoweringResult; max_pebbles::Int=0) -> ReversibleCircuit

Bennett construction with Knill's pebbling and wire reuse at the GateGroup level.
Reached via `bennett(lr; strategy=PebbledGroupStrategy(max_pebbles))`
(Bennett-i2ca / U55) or the `pebbled_group_bennett` legacy alias.

Each GateGroup is a pebble unit. After un-pebbling a group, its wires are freed
back to the allocator. Subsequent groups get recycled wire indices.

Requires lr.gate_groups to be populated (from lower()).

## Fallback behaviour

Three conditions cause this function to fall back to a simpler construction
rather than attempt pebbling:

1. **`groups` empty** — no gate grouping available (e.g., legacy `lower()`
   path without gate-group tracking). Falls back to `bennett(lr)`.

2. **In-place ops detected** (Bennett-07r) — any group whose `result_wires`
   extend outside its allocated `[wire_start..wire_end]` range. Cuccaro's
   in-place adder writes results BACK into an operand's wires — it reuses
   the same qubits for output that held an input. This happens ONLY under an
   explicit `add=:cuccaro` (`:auto` resolves to ripple since Bennett-spa8 /
   U27), and only on an exclusive-reader operand — a constant, or an SSA
   name with a single operand occurrence in the whole function that is an
   argument or a fresh-wire def (Bennett-stwr, `compute_inplace_targets`);
   other adds run Cuccaro on a CNOT copy and stay inside their range. This
   is how Cuccaro achieves its 1-ancilla / 2n-3 Toffoli efficiency.
   (`ValueEagerStrategy` and `EagerStrategy` have NO such fallback — they
   are sound on in-place groups precisely because of the exclusive-reader
   criterion; see `src/pebble/value_eager.jl`.)

   Pebbling's checkpoint replay is incompatible with this pattern: when
   un-pebbling, the original group's dependency wires must still hold their
   pre-group values so the replay can recompute cleanly. Cuccaro groups
   have already overwritten those wires, so replay would compute on
   corrupted inputs and produce the wrong result.

   **Decision: fall back to `bennett(lr)`.** This sacrifices pebbling-style
   wire reuse to preserve Cuccaro's per-adder wire/Toffoli savings — which
   are strictly larger than pebbling gains on adder-heavy benchmarks.

   Making these compose (so pebbling can wrap Cuccaro groups without
   corrupting state) would require one of:
     * Snapshot-and-restore dependency wires before each in-place group's
       execution (adds 2·wire_count CNOT overhead per group — breaks the
       Cuccaro wire-count win)
     * Track an "in-place wire overwrite" graph and schedule un-pebbles
       only across groups that don't share overwritten wires (complex
       dependency-analysis change to the pebbling scheduler)
     * Decompose in-place groups into their equivalent out-of-place form
       for pebbling purposes (loses the Cuccaro gate-count win)

   None is obviously better than the current fallback for Bennett.jl's
   benchmark suite; documented as a known tradeoff.

3. **`max_pebbles ≥ n_groups`** — enough pebble budget to hold every
   group simultaneously. No pebbling needed; full Bennett equivalent.
   Falls back to `bennett(lr)`.

## Preferred path

When none of the fallbacks trigger, delegates to `checkpoint_bennett` for
the non-pebbled path (uses `wire_start`/`wire_end` info for fine-grained
checkpoints) or the explicit pebbling scheduler below when `max_pebbles`
is bounded and groups permit.
"""
function _pebbled_group_bennett_impl(lr::LoweringResult; max_pebbles::Int=0)
    # Bennett-rjk7: honor the self_reversing fast-path universally — mirrors
    # `_bennett_default` (src/bennett_transform.jl:286-294). Skipping the wrap
    # halves gate count for QROM / Sun-Borissov primitives, and the U03 probe
    # (`_validate_self_reversing!`, Bennett-egu6) catches forged tags loud per
    # CLAUDE.md §1 regardless of strategy choice.
    if lr.self_reversing
        _validate_self_reversing!(lr)
        return _build_circuit(lr.gates, lr.n_wires, lr.input_wires,
                              lr.output_wires, lr)
    end

    # Bennett-s0tn: loop-guard copy-out lives only in `_bennett_default`.
    isempty(lr.loop_guards) || return _bennett_default(lr)

    groups = lr.gate_groups
    if isempty(groups)
        return bennett(lr)
    end

    # Bennett-prtp / U04: branching CFGs (≥2 `__pred_*` groups) confuse
    # group-level wmap-based checkpointing — `__pred_*` groups have empty
    # input_ssa_vars so the wmap misses wire-level cross-deps and
    # `_remap_wire` raises "Unmapped wire N". Fall back to full Bennett on
    # any branching program; straight-line keeps pebbled-group savings.
    if _has_branching(lr)
        return bennett(lr)
    end

    # Detect in-place results (Cuccaro): result_wires outside group's wire range.
    # In-place ops modify dependency/input wires, breaking checkpoint replay.
    # See docstring "Fallback behaviour" §2 for full tradeoff analysis and
    # why this is the right default (Bennett-07r documented).
    has_inplace = any(g -> g.wire_start > 0 &&
        any(w -> w < g.wire_start || w > g.wire_end, g.result_wires), groups)
    if has_inplace
        return bennett(lr)
    end

    # Use checkpoint_bennett when wire ranges are available (preferred path).
    # Bennett-i2ca / U55: call the renamed impl directly so we don't depend
    # on bennett_strategies.jl loading (forward-reference) — same effect.
    if all(g -> g.wire_start > 0, groups)
        return _checkpoint_bennett_impl(lr)
    end

    n_groups = length(groups)
    if max_pebbles <= 0 || max_pebbles >= n_groups
        return bennett(lr)
    end

    gates = lr.gates
    input_wire_set = Set(lr.input_wires)

    # Build original result wire lookup
    orig_results = Dict{Symbol, Vector{Int}}()
    for g in groups
        orig_results[g.ssa_name] = g.result_wires
    end

    # Wire allocator: reserve input wire positions
    wa = WireAllocator()
    if !isempty(lr.input_wires)
        allocate!(wa, maximum(lr.input_wires))
    end

    # Allocate copy wires (permanent, never freed)
    n_out = length(lr.output_wires)
    copy_wires = allocate!(wa, n_out)

    # Live pebble tracking
    live_map = Dict{Symbol, ActivePebble}()

    # Ensure sufficient pebbles
    s = max(max_pebbles, min_pebbles(n_groups))

    # Generate pebbled circuit
    result = ReversibleGate[]
    _pebble_groups!(result, groups, gates, wa, live_map,
                    input_wire_set, orig_results,
                    lr.output_wires, copy_wires,
                    1, n_groups, s, true)

    total = wire_count(wa)
    return _build_circuit(result, total, lr.input_wires, copy_wires, lr)
end

# ---- checkpoint-based Bennett construction ----

"""
    _checkpoint_bennett_impl(lr::LoweringResult) -> ReversibleCircuit

Bennett construction with per-group checkpointing for wire reduction.
Reached via `bennett(lr; strategy=CheckpointStrategy())` (Bennett-i2ca /
U55) or the `checkpoint_bennett` legacy alias.

For each gate group: forward (compute), CNOT-copy result to checkpoint wires,
then reverse (freeing internal wires). Only checkpoint wires (= result size)
stay live, not the full internal wire range (carries, partial products, etc.).

Peak wires = inputs + outputs + sum(checkpoints) + max(one group's internals).
For SHA-256: ~2400 wires instead of ~5900 (full Bennett).

Requires lr.gate_groups with wire_start/wire_end populated (from lower()).
"""
function _checkpoint_bennett_impl(lr::LoweringResult)
    # Bennett-rjk7: honor the self_reversing fast-path universally — mirrors
    # `_bennett_default` (src/bennett_transform.jl:286-294). Skipping the wrap
    # halves gate count for QROM / Sun-Borissov primitives, and the U03 probe
    # (`_validate_self_reversing!`, Bennett-egu6) catches forged tags loud per
    # CLAUDE.md §1 regardless of strategy choice.
    if lr.self_reversing
        _validate_self_reversing!(lr)
        return _build_circuit(lr.gates, lr.n_wires, lr.input_wires,
                              lr.output_wires, lr)
    end

    # Bennett-s0tn: loop-guard copy-out lives only in `_bennett_default`.
    isempty(lr.loop_guards) || return _bennett_default(lr)

    groups = lr.gate_groups
    isempty(groups) && return bennett(lr)
    # Bennett-prtp / U04: branching CFGs (≥2 `__pred_*` groups) confuse
    # checkpoint replay's wmap — `__pred_*` groups have empty input_ssa_vars
    # so the wmap misses wire-level cross-deps and `_remap_wire` raises
    # "Unmapped wire N". Straight-line code has only the entry predicate and
    # keeps checkpoint savings.
    _has_branching(lr) && return bennett(lr)
    any(g -> g.wire_start <= 0, groups) && return bennett(lr)
    # In-place results (Cuccaro) modify shared wires — fall back to full bennett
    any(g -> any(w -> w < g.wire_start || w > g.wire_end, g.result_wires), groups) &&
        return bennett(lr)

    gates = lr.gates
    input_wire_set = Set(lr.input_wires)

    # Build original result wire lookup
    orig_results = Dict{Symbol, Vector{Int}}()
    for g in groups
        orig_results[g.ssa_name] = g.result_wires
    end

    # Wire allocator: reserve input wire positions
    wa = WireAllocator()
    if !isempty(lr.input_wires)
        allocate!(wa, maximum(lr.input_wires))
    end

    # Allocate permanent copy wires (never freed)
    n_out = length(lr.output_wires)
    copy_wires = allocate!(wa, n_out)

    # Checkpoint tracking: group name → checkpoint wire locations
    checkpoint_map = Dict{Symbol, Vector{Int}}()
    # live_map is used by _replay_forward! for dependency resolution
    live_map = Dict{Symbol, ActivePebble}()

    result = ReversibleGate[]

    # ---- Phase 1: Forward with checkpointing ----
    # For each group: forward → copy result to checkpoint → reverse (free internals)
    for group in groups
        _replay_forward!(result, group, gates, wa, live_map,
                        input_wire_set, orig_results)

        pebble = live_map[group.ssa_name]

        # Allocate checkpoint wires and copy result
        n_result = length(pebble.result_wires)
        ckpt = allocate!(wa, n_result)
        for (i, rw) in enumerate(pebble.result_wires)
            push!(result, CNOTGate(rw, ckpt[i]))
        end
        checkpoint_map[group.ssa_name] = ckpt

        # Reverse group (frees result + internal wires)
        _replay_reverse!(result, group, gates, wa, live_map, input_wire_set)

        # Re-register with checkpoint wires so downstream groups can find deps
        live_map[group.ssa_name] = ActivePebble(ckpt, Int[], Dict{Int,Int}())
    end

    # ---- Phase 2: Copy output to permanent wires ----
    # Map original output wires → current checkpoint locations
    wire_current = Dict{Int,Int}()
    for (name, ckpt) in checkpoint_map
        orig = orig_results[name]
        for (i, old_w) in enumerate(orig)
            if i <= length(ckpt)
                wire_current[old_w] = ckpt[i]
            end
        end
    end
    for (j, orig_w) in enumerate(lr.output_wires)
        src = get(wire_current, orig_w, orig_w)
        push!(result, CNOTGate(src, copy_wires[j]))
    end

    # ---- Phase 3: Cleanup remaining checkpoints (reverse order) ----
    # Skip groups already cleaned by EAGER during Phase 1
    for group in reverse(groups)
        haskey(checkpoint_map, group.ssa_name) || continue

        old_ckpt = checkpoint_map[group.ssa_name]

        # Re-forward group (reads deps from live_map which has checkpoints)
        _replay_forward!(result, group, gates, wa, live_map,
                        input_wire_set, orig_results)

        pebble = live_map[group.ssa_name]

        # Un-copy: CNOT result → checkpoint (zeros checkpoint since both have same value)
        for (i, rw) in enumerate(pebble.result_wires)
            push!(result, CNOTGate(rw, old_ckpt[i]))
        end

        # Reverse group (frees result + internal)
        _replay_reverse!(result, group, gates, wa, live_map, input_wire_set)

        # Free checkpoint wires (now zero)
        free!(wa, old_ckpt)
        delete!(checkpoint_map, group.ssa_name)
    end

    total = wire_count(wa)
    return _build_circuit(result, total, lr.input_wires, copy_wires, lr)
end
