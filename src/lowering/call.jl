# ---- function call inlining ----

# Bennett-atf4: derive the concrete Julia argument Tuple type of a registered
# callee from its method table. Replaces the old `Tuple{UInt64, ...}` hardcode
# that only worked for scalar-UInt64 callees (all 44 registered today). Unblocks
# NTuple-aggregate callees like `linear_scan_pmap_set(::NTuple{9,UInt64}, ::Int8, ::Int8)`.
#
# Fail-loud rejects: zero-method, multi-method, Vararg, arity-mismatch.
# See docs/design/alpha_consensus.md.
function _callee_arg_types(inst::IRCall)::Type{<:Tuple}
    # Bennett-k3ej (hostile review, nit 1): a Symbol callee is the closed-world
    # C-track shape (BVM ADR 0020 D1) — it has no Julia method table and can
    # NEVER be inlined into a circuit. Without this guard the failure would be
    # an unattributed MethodError from `methods(::Symbol)`; convert to Rule 1.
    inst.callee isa Function ||
        error("lower_call!: Symbol callee `", inst.callee, "` cannot be inlined ",
              "via the circuit lowerer — Symbol-callee IRCalls are the ",
              "closed-world C-track (BVM ADR 0020); route this ParsedIR ",
              "through BennettVM lower_vm instead. (Bennett-k3ej)")
    ms = methods(inst.callee)
    fname = nameof(inst.callee)
    if isempty(ms)
        throw(AssertionError("lower_call!: callee `$(fname)` has no methods (cannot derive " *
              "arg types). Ensure the callee is a Julia Function registered " *
              "via register_callee!. (Bennett-atf4)"))
    end
    if length(ms) != 1
        sigs = join(["  $(m.sig)" for m in ms], "\n")
        throw(AssertionError("lower_call!: callee `$(fname)` has $(length(ms)) methods; " *
              "gate-level inlining requires exactly one concrete method " *
              "(Bennett-atf4 MVP). Candidates:\n$sigs"))
    end
    m = first(ms)
    params = m.sig.parameters  # (typeof(callee), arg1, arg2, ...)
    if !isempty(params) && Base.isvarargtype(params[end])
        throw(AssertionError("lower_call!: callee `$(fname)` has a Vararg method signature " *
              "$(m.sig); gate-level inlining requires fixed arity " *
              "(Bennett-atf4 MVP)."))
    end
    arity = length(params) - 1
    if arity != length(inst.args)
        throw(AssertionError("lower_call!: callee `$(fname)` method arity = $arity but " *
              "IRCall supplies $(length(inst.args)) arg(s). " *
              "Method signature: $(m.sig). This is caller-side miswiring " *
              "— check the IRCall emitter. (Bennett-atf4)"))
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
    length(params) == length(inst.arg_widths) || throw(DimensionMismatch(
        "lower_call!: arg_widths length mismatch for callee `$(fname)`: " *
        "method has $(length(params)) params, IRCall supplies " *
        "$(length(inst.arg_widths)) width(s). (Bennett-atf4)"))
    for (i, T) in enumerate(params)
        expected = sizeof(T) * 8
        actual = inst.arg_widths[i]
        expected == actual || throw(DimensionMismatch(
            "lower_call!: arg width mismatch for callee `$(fname)` " *
            "arg #$i (type $T): expected $expected bits (from method " *
            "signature), got $actual bits (from IRCall.arg_widths). " *
            "This is an IRCall-emitter bug — the caller computed widths " *
            "inconsistent with the callee's Julia method signature. " *
            "(Bennett-atf4)"))
    end
    return nothing
end

# Bennett-0a6f / Bennett-jgyx: loop bound of an inlined callee. A named
# constant, whatever the caller passes: an unrolled iteration costs its gates
# whether or not it executes, every registered library callee with a loop
# (soft_udiv/urem, soft_fdiv, the inverse-trig / hyperbolic soft-floats, …) is
# sized to fit 64, and the caller's `max_loop_iterations` is about the CALLER's
# own loops — letting it leak in made Int8 `÷` at max_loop_iterations=256 about
# 4x bigger and 18x slower to compile. A callee needing more than 64
# iterations is a loud capability limit tracked in Bennett-jgyx.
const _CALLEE_LOOP_ITERATIONS = 64
_callee_loop_bound(::Int) = _CALLEE_LOOP_ITERATIONS

# Bennett-0a6f: the `lower()` kwargs an inlined callee is lowered with — the
# caller's resolved options, except the loop bound (`_callee_loop_bound`). Spelled out
# field by field so each field's callee semantics is an explicit decision: a
# new `LowerOptions` field must be added here too (test_0a6f checks that every
# field is forwarded).
_callee_lower_kwargs(o::LowerOptions) = (
    max_loop_iterations = _callee_loop_bound(o.max_loop_iterations),
    use_inplace = o.use_inplace, fold_constants = o.fold_constants,
    compact_calls = o.compact_calls, add = o.add, mul = o.mul,
    target = o.target, auto_self_reversing = o.auto_self_reversing,
    mem = o.mem, persistent_impl = o.persistent_impl, hashcons = o.hashcons)

"""
    lower_call!(gates, wa, vw, inst::IRCall; compact=false, loop_guards=LoopGuard[],
                callee_opts=LowerOptions())

Inline a function call by pre-compiling the callee into a sub-circuit and
inserting its forward gates with wire remapping. The callee's inputs are
connected via CNOT-copy from the caller's argument wires, and the callee's
output wires become the caller's result wires.

The callee is lowered under `callee_opts` — the caller's resolved `lower()`
options (Bennett-0a6f), with the loop bound from `_callee_loop_bound`. The
default `LowerOptions()` is `lower`'s own defaults. The callee IR cache
(`_extract_parsed_ir_cached`) sits BEFORE lowering and is option-free, so a
callee lowered under different options is never served from a cache.
"""
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false,
                     loop_guards::Vector{LoopGuard}=LoopGuard[],
                     callee_opts::LowerOptions=LowerOptions())
    # Pre-compile the callee function. Bennett-atf4: arg types derived from
    # methods() not hardcoded UInt64 — unblocks aggregate callees.
    arg_types = _callee_arg_types(inst)
    _assert_arg_widths_match(inst, arg_types)
    callee_parsed = _extract_parsed_ir_cached(inst.callee, arg_types)
    # Bennett-s0tn: if the callee has a data-dependent loop, its
    # `loop_guards` reference callee-numbered convergence wires; they MUST be
    # remapped (via `wmap`) and appended to the caller's accumulator below —
    # never silently dropped. Bennett-0a6f / jgyx: lowered under the caller's
    # options, not defaults + a hard-coded 64 (see `_callee_lower_kwargs`).
    callee_lr = lower(callee_parsed; _callee_lower_kwargs(callee_opts)...)

    if compact
        # Apply Bennett to callee: forward + copy output + reverse.
        # This frees all intermediate wires, keeping only the output.
        callee_circuit = bennett(callee_lr)

        # Bennett-9k7n: callee wire k lands on `wmap[k]` — NOT on
        # `wire_count(wa) + k`. `allocate!` pops the free list first (QROM
        # frees its scratch), so the block it returns need not be contiguous.
        wmap = allocate!(wa, callee_circuit.n_wires)

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = wmap[callee_circuit.input_wires[callee_start + bit]]
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert ALL callee gates (forward + copy + reverse), remapped via wmap
        for g in callee_circuit.gates
            push!(gates, _remap_gate(g, wmap))
        end

        # The callee's output wires (remapped) are the Bennett copy wires
        result_wires = [wmap[w] for w in callee_circuit.output_wires]
        vw[inst.dest] = result_wires

        # Bennett-s0tn: the callee circuit's loop-check wires (post-bennett
        # `conv_copy`) carry the convergence bit, set by the loop-copy CNOT
        # inside `callee_circuit.gates` which we just inlined. Remap through
        # `wmap` and append to the caller's accumulator so the caller's
        # `simulate` checks them. Never drop them.
        for lg in callee_circuit.loop_check_wires
            push!(loop_guards, LoopGuard(wmap[lg.wire],
                                         lg.header_label, lg.K))
        end
    else
        # Original behavior: insert only forward gates, caller's Bennett handles cleanup
        wmap = allocate!(wa, callee_lr.n_wires)   # Bennett-9k7n: see above

        # Connect caller arguments → callee input wires (CNOT copy)
        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
            for bit in 1:w
                callee_wire = wmap[callee_lr.input_wires[callee_start + bit]]
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        # Insert callee's forward gates, remapped via wmap
        for g in callee_lr.gates
            push!(gates, _remap_gate(g, wmap))
        end

        # The callee's output wires (remapped) become the result
        result_wires = [wmap[w] for w in callee_lr.output_wires]
        vw[inst.dest] = result_wires

        # Bennett-s0tn: the callee LR's loop guards reference callee-
        # numbered forward-pass convergence wires. We just inlined the
        # callee's forward gates through `wmap` — including the
        # `lower_loop!`-emitted convergence CNOT — so each `conv_w` now
        # lives at `wmap[lg.wire]` in the caller's wire space. The
        # caller's Bennett wrap will copy it out. Append remapped guards.
        for lg in callee_lr.loop_guards
            push!(loop_guards, LoopGuard(wmap[lg.wire],
                                         lg.header_label, lg.K))
        end
    end
end

# Bennett-9k7n: remap callee wire k → caller wire `wmap[k]` (the vector
# `allocate!` returned; may be non-contiguous after free-list reuse).
_remap_gate(g::NOTGate, wmap::Vector{Int}) = NOTGate(wmap[g.target])
_remap_gate(g::CNOTGate, wmap::Vector{Int}) =
    CNOTGate(wmap[g.control], wmap[g.target])
_remap_gate(g::ToffoliGate, wmap::Vector{Int}) =
    ToffoliGate(wmap[g.control1], wmap[g.control2], wmap[g.target])

