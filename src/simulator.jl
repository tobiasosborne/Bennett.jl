@inline apply!(b::Vector{Bool}, g::NOTGate)     = (b[g.target] ⊻= true; nothing)
@inline apply!(b::Vector{Bool}, g::CNOTGate)    = (b[g.target] ⊻= b[g.control]; nothing)
@inline apply!(b::Vector{Bool}, g::ToffoliGate) = (b[g.target] ⊻= b[g.control1] & b[g.control2]; nothing)

"""
    _assert_input_fits(v, w, k) -> nothing

Bennett-6fg9 / U19: per-input bit-width bounds check. An `Integer` value
`v` intended for a `w`-bit input at position `k` must be representable
in `w` bits under either signed or unsigned semantics. Silent truncation
via `(v >> i) & 1` would otherwise mis-ingest over-wide inputs.
"""
@inline function _assert_input_fits(v::Integer, w::Int, k::Int)
    w > 0 || throw(ArgumentError("simulate: input $k has width $w (must be > 0)"))
    w >= 64 && return nothing   # UInt64 upper-bound subsumes Int64
    # Allow signed-representable [-2^(w-1), 2^(w-1)) OR unsigned
    # [0, 2^w). Anything outside both ranges would silently wrap.
    signed_lo  = -(Int128(1) << (w - 1))
    signed_hi  =  (Int128(1) << (w - 1)) - 1
    unsigned_hi = (Int128(1) <<  w     ) - 1
    vi = Int128(v)
    ok = (signed_lo <= vi <= signed_hi) || (0 <= vi <= unsigned_hi)
    ok || throw(ArgumentError(
        "simulate: input $k value $v does not fit in $w bits"))
    return nothing
end

function simulate(circuit::ReversibleCircuit, input::Integer)
    length(circuit.input_widths) == 1 || error("simulate(circuit, input) requires single-input circuit, got $(length(circuit.input_widths)) inputs")
    return _simulate(circuit, (input,))
end

function simulate(circuit::ReversibleCircuit, inputs::Tuple{Vararg{Integer}})
    return _simulate(circuit, inputs)
end

function _simulate(circuit::ReversibleCircuit, inputs::Tuple)
    # Bennett-6fg9 / U19: guard arity and per-input bit-width at entry.
    # Pre-fix, a too-long tuple silently dropped the extras, a too-short
    # tuple crashed with a raw BoundsError deep in the input-ingest loop,
    # and an over-wide value silently wrapped via `(v >> i) & 1`.
    length(inputs) == length(circuit.input_widths) || throw(ArgumentError(
        "simulate: expected $(length(circuit.input_widths)) inputs, got " *
        "$(length(inputs)) (input_widths = $(circuit.input_widths))"))
    for (k, (v, w)) in enumerate(zip(inputs, circuit.input_widths))
        _assert_input_fits(v, w, k)
    end
    circuit.n_wires > 0 || throw(ArgumentError(
        "simulate: circuit has n_wires = 0 (empty circuit)"))

    bits = zeros(Bool, circuit.n_wires)

    offset = 0
    for (k, w) in enumerate(circuit.input_widths)
        v = inputs[k]
        for i in 1:w
            bits[circuit.input_wires[offset + i]] = (v >> (i - 1)) & 1 == 1
        end
        offset += w
    end

    # Bennett-6azb / U58: snapshot input wires before running gates so we
    # can verify the other half of Bennett's invariant — not just
    # "ancillae return to zero" but "inputs come out unchanged". A circuit
    # that silently mutates an input but produces the right output used
    # to pass every test. The snapshot is bit-copied out of `bits` in
    # input_wires order so the post-run comparison reports the wire
    # index the user can bisect on.
    input_snapshot = Bool[bits[w] for w in circuit.input_wires]

    for gate in circuit.gates
        apply!(bits, gate)
    end

    for w in circuit.ancilla_wires
        bits[w] && error("Ancilla wire $w not zero — Bennett construction bug")
    end

    for (k, w) in pairs(circuit.input_wires)
        bits[w] == input_snapshot[k] || error(
            "input wire $w changed from $(input_snapshot[k]) to $(bits[w]) " *
            "— Bennett input-preservation invariant violated " *
            "(input index $k of $(length(circuit.input_wires)); n_wires=" *
            "$(circuit.n_wires), n_gates=$(length(circuit.gates)))")
    end

    return _read_output(bits, circuit.output_wires, circuit.output_elem_widths)
end

"""
Read the output value from the simulation bit vector. Returns Int8/16/32/64
for single-element outputs, or a Tuple for multi-element (insertvalue) outputs.
Note: return type is inherently unstable (depends on circuit's output_elem_widths).
"""
function _read_output(bits, output_wires, elem_widths)
    if length(elem_widths) == 1
        return _read_int(bits, output_wires, 1, elem_widths[1])
    else
        # Multi-element return → tuple
        vals = Vector{Int64}(undef, length(elem_widths))
        off = 0
        for (k, ew) in enumerate(elem_widths)
            vals[k] = _read_int(bits, output_wires, off + 1, ew)
            off += ew
        end
        return Tuple(vals)
    end
end

function _read_int(bits, wires, start, width)
    raw = UInt64(0)
    for i in 0:width-1
        raw |= UInt64(bits[wires[start + i]]) << i
    end
    if width == 8;      reinterpret(Int8, UInt8(raw & 0xFF))
    elseif width == 16; reinterpret(Int16, UInt16(raw & 0xFFFF))
    elseif width == 32; reinterpret(Int32, UInt32(raw & 0xFFFFFFFF))
    elseif width == 64; reinterpret(Int64, raw)
    else                Int(raw & ((UInt64(1) << width) - 1))
    end
end
