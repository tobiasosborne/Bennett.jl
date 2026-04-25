# ---- Tabulate strategy: classical eval → QROM lookup ----
#
# For pure functions at small total input bit width, expression-graph
# compilation holds every SSA intermediate live simultaneously, producing
# O(n_ssa) wires even for W as small as 2 (e.g. x^2+3x+1 at W=2 → 43 wires).
# We bypass the whole lowering by evaluating f classically on all 2^W
# inputs, packing the results into a compile-time table, and emitting the
# transformation (x, 0^W_out) → (x, f(x)) via the existing Babbush-Gidney
# QROM (src/qrom.jl).
#
# Cost: 2(L-1) Toffoli (self-reversing, no Bennett wrap) + O(L·W_out) CNOT,
# L = 2^sum(input_widths). Complexity independent of expression depth —
# depends only on input-domain size.

"""
    _tabulate_input_widths(arg_types, bit_width) -> Vector{Int}

Per-argument bit widths. `bit_width=0` means use each type's natural width
(`sizeof(T)*8`). `bit_width > 0` overrides all widths (matches `_narrow_ir`).
"""
function _tabulate_input_widths(arg_types::Type{<:Tuple}, bit_width::Int)
    widths = Int[]
    for T in arg_types.parameters
        w = bit_width > 0 ? bit_width : sizeof(T) * 8
        push!(widths, w)
    end
    return widths
end

"""
    _tabulate_applicable(arg_types, bit_width) -> (Bool, String)

Predicate for whether the tabulate path can handle this compile. Returns
`(applicable, reason)`. Non-applicable reasons are short messages for the
explicit-`:tabulate` error path.
"""
function _tabulate_applicable(arg_types::Type{<:Tuple}, bit_width::Int)
    isempty(arg_types.parameters) && return (false, "no arguments")
    for T in arg_types.parameters
        T <: Integer || return (false, "non-integer arg type $T (got $(arg_types.parameters))")
    end
    widths = _tabulate_input_widths(arg_types, bit_width)
    total = sum(widths)
    # Hard cap: 2^16 = 65536 entries. Beyond that the table itself is larger
    # than the IR-lowered circuit for any realistic function.
    total <= 16 || return (false, "total input width $total exceeds tabulate cap (16)")
    return (true, "")
end

"""
    _tabulate_auto_picks(parsed, arg_types, bit_width) -> Bool

Cost-model dispatch: does `:auto` pick tabulate for this compile?

Two-factor heuristic:
  1. **Size**: total input bit width ≤ 4 (table ≤ 16 entries). QROM cost grows
     as 2(2^W_in - 1) Toffoli; beyond W=4 the expression path nearly always
     catches up.
  2. **Complexity**: the IR contains at least one O(W²)-lowered op
     (`mul`, `udiv`, `sdiv`, `urem`, `srem`). Pure add/sub/shift/bitwise
     functions lower to O(W) gates via ripple — cheaper than any QROM.

Both must hold. This correctly picks tabulate for `x^2+3x+1` @ W=2 and
keeps `x+1` on the expression path at every width.
"""
function _tabulate_auto_picks(parsed::ParsedIR, arg_types::Type{<:Tuple}, bit_width::Int)
    ok, _ = _tabulate_applicable(arg_types, bit_width)
    ok || return false
    widths = _tabulate_input_widths(arg_types, bit_width)
    sum(widths) <= 4 || return false
    return _has_expensive_op(parsed)
end

"""Does this parsed IR contain an op whose expression-path lowering is O(W²) or worse?"""
function _has_expensive_op(parsed::ParsedIR)
    for block in parsed.blocks
        for inst in block.instructions
            if inst isa IRBinOp && inst.op in (:mul, :udiv, :sdiv, :urem, :srem)
                return true
            end
        end
    end
    return false
end

"""
Reinterpret a UInt64 bit pattern as type T (Integer), placing the low
`width` bits of `raw` into T's bit pattern. T gets the full signed/unsigned
interpretation of its own width; we only care that the low `width` bits
match `raw`. For W < sizeof(T)*8 the high bits are zero (idx is in the
nonnegative range 0..2^W-1 by construction).
"""
function _raw_bits_to_type(raw::UInt64, ::Type{T}) where {T<:Integer}
    if T === Int8 || T === UInt8
        return reinterpret(T, UInt8(raw & 0xff))
    elseif T === Int16 || T === UInt16
        return reinterpret(T, UInt16(raw & 0xffff))
    elseif T === Int32 || T === UInt32
        return reinterpret(T, UInt32(raw & 0xffffffff))
    elseif T === Int64 || T === UInt64
        return reinterpret(T, raw)
    elseif T === Bool
        return (raw & 0x1) != 0
    else
        # Fallback: try T(x) for unknown integer types (BigInt etc.)
        return T(raw)
    end
end

"""Reinterpret any Integer result into UInt64 bits (low bits preserved)."""
function _result_to_uint64(y::Integer)
    if y isa Bool
        return UInt64(y)
    elseif y isa Int8
        return UInt64(reinterpret(UInt8, y))
    elseif y isa Int16
        return UInt64(reinterpret(UInt16, y))
    elseif y isa Int32
        return UInt64(reinterpret(UInt32, y))
    elseif y isa Int64
        return reinterpret(UInt64, y)
    elseif y isa Unsigned
        return UInt64(y)
    else
        return UInt64(y & typemax(UInt64))
    end
end

"""
    _tabulate_build_table(f, arg_types, input_widths, out_width) -> Vector{UInt64}

Enumerate every input tuple in [0, 2^w_k) per arg, evaluate `f`, and pack
the result into `low(out_width)` of a UInt64. Returns a vector of length
`2^sum(input_widths)`.

The idx layout matches the simulator: input k occupies bits
`[sum(W_1..W_{k-1}), sum(W_1..W_k))` of the flat index, LSB-first within
each arg.
"""
function _tabulate_build_table(f, arg_types::Type{<:Tuple},
                               input_widths::Vector{Int}, out_width::Int)
    L = 1 << sum(input_widths)
    table = Vector{UInt64}(undef, L)
    mask_out = out_width == 64 ? typemax(UInt64) : (UInt64(1) << out_width) - UInt64(1)
    arg_T = arg_types.parameters

    for raw_idx in 0:(L - 1)
        args = _unpack_args(UInt64(raw_idx), input_widths, arg_T)
        y = f(args...)
        y isa Integer || error("tabulate: f returned $(typeof(y)); only Integer " *
                               "returns are supported for tabulate strategy")
        table[raw_idx + 1] = _result_to_uint64(y) & mask_out
    end
    return table
end

"""Split a packed index into per-arg values, LSB-first.

Bennett-b2fs / U148: returns a `Tuple` (heterogeneously typed,
stack-allocated) instead of the previous `Vector{Any}` (per-row
heap allocation + boxed elements). `_tabulate_build_table` runs
this once per table row and `2^total_in` rows can reach 16M+ on
24-bit input spaces; the Vector{Any} form was 32+ bytes of
garbage per call.
"""
function _unpack_args(raw::UInt64, input_widths::Vector{Int}, arg_T)
    n = length(input_widths)
    return ntuple(n) do k
        # Shift past the first (k-1) args to reach this arg's window.
        prefix_w = 0
        @inbounds for j in 1:(k - 1)
            prefix_w += input_widths[j]
        end
        @inbounds w = input_widths[k]
        m = (UInt64(1) << w) - UInt64(1)
        v = (raw >> prefix_w) & m
        @inbounds _raw_bits_to_type(v, arg_T[k])
    end
end

"""
    lower_tabulate(f, arg_types, input_widths; out_width) -> LoweringResult

Build a `LoweringResult` that computes `(x, 0^W_out) → (x, f(x))` via QROM.
Emits a single `emit_qrom!` over a compile-time table built by evaluating
`f` on every input. Marks the result `self_reversing=true` so `bennett()`
skips the copy+uncompute wrap — QROM is already self-clean.
"""
function lower_tabulate(f, arg_types::Type{<:Tuple},
                        input_widths::Vector{Int}; out_width::Int)
    1 <= out_width <= 64 ||
        error("tabulate: out_width must be in 1..64, got $out_width")

    total_in = sum(input_widths)
    L = 1 << total_in

    table = _tabulate_build_table(f, arg_types, input_widths, out_width)

    wa = WireAllocator()
    gates = ReversibleGate[]

    # Allocate input wires, flat layout matching the simulator's expectation.
    input_wires = allocate!(wa, total_in)

    # QROM requires power-of-two L; by construction L = 2^total_in is one.
    # idx_wires are the input wires in-order (LSB-first within each arg,
    # args concatenated — matches simulator).
    output_wires = emit_qrom!(gates, wa, table, input_wires, out_width)

    return LoweringResult(gates, wire_count(wa), input_wires, output_wires,
                          copy(input_widths), [out_width], Set{Int}(),
                          GateGroup[], true)   # self_reversing = true
end
