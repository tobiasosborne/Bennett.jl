# ---- function call inlining ----

# Bennett-atf4: derive the concrete Julia argument Tuple type of a registered
# callee from its method table. Replaces the old `Tuple{UInt64, ...}` hardcode
# that only worked for scalar-UInt64 callees (all 44 registered today). Unblocks
# NTuple-aggregate callees like `linear_scan_pmap_set(::NTuple{9,UInt64}, ::Int8, ::Int8)`.
#
# Fail-loud rejects: zero-method, multi-method, Vararg, arity-mismatch.
# See docs/design/alpha_consensus.md.
function _callee_arg_types(inst::IRCall)::Type{<:Tuple}
    ms = methods(inst.callee)
    fname = nameof(inst.callee)
    if isempty(ms)
        error("lower_call!: callee `$(fname)` has no methods (cannot derive " *
              "arg types). Ensure the callee is a Julia Function registered " *
              "via register_callee!. (Bennett-atf4)")
    end
    if length(ms) != 1
        sigs = join(["  $(m.sig)" for m in ms], "\n")
        error("lower_call!: callee `$(fname)` has $(length(ms)) methods; " *
              "gate-level inlining requires exactly one concrete method " *
              "(Bennett-atf4 MVP). Candidates:\n$sigs")
    end
    m = first(ms)
    params = m.sig.parameters  # (typeof(callee), arg1, arg2, ...)
    if !isempty(params) && Base.isvarargtype(params[end])
        error("lower_call!: callee `$(fname)` has a Vararg method signature " *
              "$(m.sig); gate-level inlining requires fixed arity " *
              "(Bennett-atf4 MVP).")
    end
    arity = length(params) - 1
    if arity != length(inst.args)
        error("lower_call!: callee `$(fname)` method arity = $arity but " *
              "IRCall supplies $(length(inst.args)) arg(s). " *
              "Method signature: $(m.sig). This is caller-side miswiring " *
              "— check the IRCall emitter. (Bennett-atf4)")
    end
    return Tuple{params[2:end]...}
end

# Bennett-atf4: cross-check that `inst.arg_widths[i]` matches the bit width of
# the i-th callee method param. Closes the latent silent-misalignment bug noted
# in docs/design/p6_research_local.md §12.4. Empirically a no-op for every
# currently-registered callee (R8 instrumentation 2026-04-21 — zero mismatches).
function _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple})::Nothing
    fname = nameof(inst.callee)
    params = arg_types.parameters
    length(params) == length(inst.arg_widths) || error(
        "lower_call!: arg_widths length mismatch for callee `$(fname)`: " *
        "method has $(length(params)) params, IRCall supplies " *
        "$(length(inst.arg_widths)) width(s). (Bennett-atf4)")
    for (i, T) in enumerate(params)
        expected = sizeof(T) * 8
        actual = inst.arg_widths[i]
        expected == actual || error(
            "lower_call!: arg width mismatch for callee `$(fname)` " *
            "arg #$i (type $T): expected $expected bits (from method " *
            "signature), got $actual bits (from IRCall.arg_widths). " *
            "This is an IRCall-emitter bug — the caller computed widths " *
            "inconsistent with the callee's Julia method signature. " *
            "(Bennett-atf4)")
    end
    return nothing
end

"""
    lower_call!(gates, wa, vw, inst::IRCall)

Inline a function call by pre-compiling the callee into a sub-circuit and
inserting its forward gates with wire remapping. The callee's inputs are
connected via CNOT-copy from the caller's argument wires, and the callee's
output wires become the caller's result wires.
"""
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false)
    # Pre-compile the callee function. Bennett-atf4: arg types derived from
    # methods() not hardcoded UInt64 — unblocks aggregate callees.
    arg_types = _callee_arg_types(inst)
    _assert_arg_widths_match(inst, arg_types)
    callee_parsed = _extract_parsed_ir_cached(inst.callee, arg_types)
    callee_lr = lower(callee_parsed; max_loop_iterations=64)

    if compact
        # Apply Bennett to callee: forward + copy output + reverse.
        # This frees all intermediate wires, keeping only the output.
        callee_circuit = bennett(callee_lr)

        wire_offset = wire_count(wa)
        allocate!(wa, callee_circuit.n_wires)

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = callee_circuit.input_wires[callee_start + bit] + wire_offset
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert ALL callee gates (forward + copy + reverse) with wire offset
        for g in callee_circuit.gates
            push!(gates, _remap_gate_offset(g, wire_offset))
        end

        # The callee's output wires (remapped) are the Bennett copy wires
        result_wires = [w + wire_offset for w in callee_circuit.output_wires]
        vw[inst.dest] = result_wires
    else
        # Original behavior: insert only forward gates, caller's Bennett handles cleanup
        wire_offset = wire_count(wa)
        allocate!(wa, callee_lr.n_wires)

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = callee_lr.input_wires[callee_start + bit] + wire_offset
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert callee's forward gates with wire offset
        for g in callee_lr.gates
            push!(gates, _remap_gate_offset(g, wire_offset))
        end

        # The callee's output wires (remapped) become the result
        result_wires = [w + wire_offset for w in callee_lr.output_wires]
        vw[inst.dest] = result_wires
    end
end

function _remap_gate_offset(g::NOTGate, offset::Int)
    NOTGate(g.target + offset)
end
function _remap_gate_offset(g::CNOTGate, offset::Int)
    CNOTGate(g.control + offset, g.target + offset)
end
function _remap_gate_offset(g::ToffoliGate, offset::Int)
    ToffoliGate(g.control1 + offset, g.control2 + offset, g.target + offset)
end

