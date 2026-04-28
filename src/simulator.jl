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

"""
    simulate(c::ReversibleCircuit, input::Integer) -> Integer
    simulate(c::ReversibleCircuit, inputs::Tuple{Vararg{Integer}}) -> Integer | Tuple

Bit-vector simulation of `c` on the given input(s). Returns the output as
`IntN` (signed, default) or `UIntN` when input types are all `Unsigned`
and width-aligned with the output (Bennett-zc50 / U100 heuristic). For
multi-element outputs — e.g. tuple returns lowered via `insertvalue` —
returns a `Tuple` shaped like the source function's return type.

The single-`Integer` form requires `length(c.input_widths) == 1` and is
sugar for the tuple form. Inputs are validated for arity (Bennett-6fg9 /
U19) and per-input bit-width fit — values outside both signed and
unsigned ranges of the declared width raise `ArgumentError` rather than
silently wrapping via `(v >> i) & 1`.

After running every gate forward, asserts Bennett's invariants:
  (1) every wire in `c.ancilla_wires` is zero (ancilla-clean), and
  (2) every wire in `c.input_wires` holds its initial value
      (input-preservation, Bennett-6azb / U58).
A violation raises `ErrorException` naming the offending wire index.

# Example
```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> simulate(c, Int8(5))
6

julia> simulate(c, Int8(-1))   # 8-bit overflow wraps mod 2^8
0

julia> c2 = reversible_compile((x, y) -> x + y, Int8, Int8);

julia> simulate(c2, (Int8(3), Int8(4)))
7

julia> c3 = reversible_compile(x -> (x, Int8(2) * x), Int8);

julia> simulate(c3, Int8(7))
(7, 14)
```
"""
function simulate(circuit::ReversibleCircuit, input::Integer)
    length(circuit.input_widths) == 1 || error("simulate(circuit, input) requires single-input circuit, got $(length(circuit.input_widths)) inputs")
    return _simulate(circuit, (input,))
end

function simulate(circuit::ReversibleCircuit, inputs::Tuple{Vararg{Integer}})
    return _simulate(circuit, inputs)
end

"""
    simulate(circuit::ReversibleCircuit, ::Type{T}, input::Integer) where T<:Integer -> T
    simulate(circuit::ReversibleCircuit, ::Type{T}, inputs::Tuple) where T<:Integer -> T

Type-stable scalar variant. The caller specifies the expected return
type `T` (e.g. `Int8`, `UInt32`). Uses bit-pattern reinterpret (`raw % T`)
so a wider `T` is sign-extended from a signed source and zero-extended
from an unsigned source — same semantics as Julia's standard
`Integer % Type` idiom.

Use this overload from hot loops to avoid the 9-arm
`Union{Int8,…,UInt64,Tuple}` return type of the untyped overload, which
would otherwise force runtime union-dispatch on each comparison.

For multi-element circuit outputs (insertvalue tuples), use the untyped
overload and dispatch on the returned `Tuple`.

(Bennett-59jj / U47 cut: typed-overload return-type elimination.)
"""
function simulate(circuit::ReversibleCircuit, ::Type{T}, input::Integer) where T<:Integer
    length(circuit.input_widths) == 1 || throw(ArgumentError(
        "simulate(circuit, T, input) requires single-input circuit, got " *
        "$(length(circuit.input_widths)) inputs"))
    return simulate(circuit, T, (input,))
end

function simulate(circuit::ReversibleCircuit, ::Type{T},
                  inputs::Tuple{Vararg{Integer}}) where T<:Integer
    length(circuit.output_elem_widths) == 1 || throw(ArgumentError(
        "simulate(circuit, T<:Integer, inputs): circuit has " *
        "$(length(circuit.output_elem_widths))-element output; use the " *
        "untyped overload and dispatch on the returned Tuple"))
    8 * sizeof(T) >= circuit.output_elem_widths[1] || throw(ArgumentError(
        "simulate: T=$T (sizeof $(sizeof(T)) bytes) cannot hold " *
        "$(circuit.output_elem_widths[1])-bit output"))
    raw = _simulate(circuit, inputs)::Integer
    return raw % T
end

function _simulate(circuit::ReversibleCircuit, inputs::Tuple)
    bits = zeros(Bool, circuit.n_wires)
    return _simulate_with_buffer!(bits, circuit, inputs)
end

"""
    simulate!(buffer::Vector{Bool}, circuit::ReversibleCircuit, inputs) -> output

Bennett-fehu / U105: in-place variant of [`simulate`](@ref) that reuses a
caller-managed `Vector{Bool}` buffer instead of allocating a fresh one
per call. Hot-loop callers (sweep harnesses, fuzzers, exhaustive Int8
verification, soft-float bit-exact sweeps with thousands of inputs) can
allocate `buffer = Vector{Bool}(undef, circuit.n_wires)` once and reuse
it — saving the per-call zeros() allocation that costs ~O(n_wires).

The buffer must have `length(buffer) == circuit.n_wires`; the function
asserts this loud (Bennett-cklf-style contract) rather than silently
truncating. Contents are reset to `false` before each call so the
caller does not need to fill!() it themselves.

# Example

```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> buf = Vector{Bool}(undef, c.n_wires);

julia> [simulate!(buf, c, (Int8(i),)) for i in 0:3]
4-element Vector{Int64}:
 1
 2
 3
 4
```
"""
function simulate!(buffer::Vector{Bool}, circuit::ReversibleCircuit,
                   inputs::Tuple{Vararg{Integer}})
    length(buffer) == circuit.n_wires || throw(ArgumentError(
        "simulate!: buffer length $(length(buffer)) != circuit.n_wires " *
        "$(circuit.n_wires) — preallocate with " *
        "Vector{Bool}(undef, circuit.n_wires)"))
    fill!(buffer, false)
    return _simulate_with_buffer!(buffer, circuit, inputs)
end

function simulate!(buffer::Vector{Bool}, circuit::ReversibleCircuit, input::Integer)
    length(circuit.input_widths) == 1 || throw(ArgumentError(
        "simulate!(buffer, circuit, input) requires single-input circuit, " *
        "got $(length(circuit.input_widths)) inputs"))
    return simulate!(buffer, circuit, (input,))
end

function _simulate_with_buffer!(bits::Vector{Bool}, circuit::ReversibleCircuit,
                                 inputs::Tuple)
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
        bits[w] && error("Ancilla wire $w not zero post-circuit — uncomputation " *
                          "invariant violated. The circuit may have been built " *
                          "via bennett(), pebbled_bennett(), value_eager_bennett(), " *
                          "checkpoint_bennett(), or a custom strategy; the bug is " *
                          "in whichever construction produced this gate sequence " *
                          "(Bennett-ajap / U202).")
    end

    for (k, w) in pairs(circuit.input_wires)
        bits[w] == input_snapshot[k] || error(
            "input wire $w changed from $(input_snapshot[k]) to $(bits[w]) " *
            "— Bennett input-preservation invariant violated " *
            "(input index $k of $(length(circuit.input_wires)); n_wires=" *
            "$(circuit.n_wires), n_gates=$(length(circuit.gates)))")
    end

    # Bennett-zc50 / U100: signedness was lost by hard-coding signed
    # reinterpret in `_read_int`. Infer from input types when the
    # width layout matches output element widths — that's the signal
    # that signedness is being propagated rather than bit-packed. If
    # every input width equals every output element width AND every
    # input is unsigned, return unsigned. Otherwise fall back to the
    # prior signed behaviour (covers mixed signedness, bit-packed
    # inputs like `NTuple{3,Int8}` fed as a UInt64, and any layout we
    # can't confidently classify). The circuit itself carries only
    # widths; threading types through ReversibleCircuit would be a §2
    # core change.
    widths_align = !isempty(inputs) && !isempty(circuit.output_elem_widths) &&
                   all(w == circuit.input_widths[1] for w in circuit.input_widths) &&
                   all(w == circuit.input_widths[1] for w in circuit.output_elem_widths)
    unsigned_out = widths_align && all(x isa Unsigned for x in inputs)
    return _read_output(bits, circuit.output_wires, circuit.output_elem_widths, unsigned_out)
end

"""
    diagnose_nonzero(c::ReversibleCircuit, input) -> NamedTuple
    diagnose_nonzero(c::ReversibleCircuit, inputs::Tuple) -> NamedTuple

Bennett-is5s / U131: replay the circuit forward without throwing on
ancilla-non-zero or input-mutation, and return a structured report of
every Bennett-invariant violation. Useful when a `simulate(c, x)` call
threw "Ancilla wire N not zero" and you need to see ALL the violations
plus enough context to bisect the buggy gate range.

Returns:

```
(
  ancilla_violations    = [(wire_index, gate_idx_first_set), ...],
  input_violations      = [(input_index, wire_index, expected, got), ...],
  output                = <whatever simulate would have returned>,
  n_gates               = length(c.gates),
  n_wires               = c.n_wires,
)
```

`gate_idx_first_set` records the gate index after which each violating
ancilla wire first became 1 (re-runs the circuit to find it). For an
ancilla left at 1 because of a missed uncompute, this is typically the
forward gate that set it; for one set then never cleared, it bisects
the buggy gate range.

Does NOT throw on violations — by design, this is the `simulate`
counterpart that surfaces them all at once. For a strict check that
throws, use `simulate` (or `verify_reversibility` for full sweeps).

# Example

```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> r = diagnose_nonzero(c, Int8(5));

julia> r.ancilla_violations
Tuple{Int64, Int64}[]

julia> r.input_violations
NamedTuple[]
```
"""
function diagnose_nonzero(circuit::ReversibleCircuit, inputs::Tuple{Vararg{Integer}})
    length(inputs) == length(circuit.input_widths) || throw(ArgumentError(
        "diagnose_nonzero: expected $(length(circuit.input_widths)) inputs, " *
        "got $(length(inputs))"))
    bits = zeros(Bool, circuit.n_wires)
    offset = 0
    for (k, w) in enumerate(circuit.input_widths)
        v = inputs[k]
        for i in 1:w
            bits[circuit.input_wires[offset + i]] = (v >> (i - 1)) & 1 == 1
        end
        offset += w
    end
    input_snapshot = Bool[bits[w] for w in circuit.input_wires]

    # First pass: just run gates and record final state.
    for g in circuit.gates
        apply!(bits, g)
    end

    ancilla_wires_set = Int[]
    for w in circuit.ancilla_wires
        bits[w] && push!(ancilla_wires_set, w)
    end

    # If any ancilla wires are dirty, replay with provenance to find
    # the gate index after which each first became 1 (the most useful
    # debugging info — points at the originating Toffoli/CNOT).
    ancilla_violations = Tuple{Int,Int}[]
    if !isempty(ancilla_wires_set)
        bits2 = zeros(Bool, circuit.n_wires)
        offset = 0
        for (k, w) in enumerate(circuit.input_widths)
            v = inputs[k]
            for i in 1:w
                bits2[circuit.input_wires[offset + i]] = (v >> (i - 1)) & 1 == 1
            end
            offset += w
        end
        first_set = Dict{Int,Int}()
        for (gi, g) in enumerate(circuit.gates)
            apply!(bits2, g)
            for w in ancilla_wires_set
                if bits2[w] && !haskey(first_set, w)
                    first_set[w] = gi
                end
            end
        end
        for w in ancilla_wires_set
            push!(ancilla_violations, (w, get(first_set, w, -1)))
        end
    end

    input_violations = NamedTuple[]
    for (k, w) in pairs(circuit.input_wires)
        if bits[w] != input_snapshot[k]
            push!(input_violations, (input_index=k, wire_index=w,
                                      expected=input_snapshot[k], got=bits[w]))
        end
    end

    widths_align = !isempty(inputs) && !isempty(circuit.output_elem_widths) &&
                   all(w == circuit.input_widths[1] for w in circuit.input_widths) &&
                   all(w == circuit.input_widths[1] for w in circuit.output_elem_widths)
    unsigned_out = widths_align && all(x isa Unsigned for x in inputs)
    output = _read_output(bits, circuit.output_wires,
                          circuit.output_elem_widths, unsigned_out)

    return (
        ancilla_violations = ancilla_violations,
        input_violations   = input_violations,
        output             = output,
        n_gates            = length(circuit.gates),
        n_wires            = circuit.n_wires,
    )
end

function diagnose_nonzero(circuit::ReversibleCircuit, input::Integer)
    length(circuit.input_widths) == 1 || throw(ArgumentError(
        "diagnose_nonzero(c, input): single-input form requires " *
        "length(c.input_widths) == 1; got $(length(circuit.input_widths))"))
    return diagnose_nonzero(circuit, (input,))
end

"""
Read the output value from the simulation bit vector. Returns
Int8/16/32/64 (or UInt… if `unsigned_out` is true) for single-element
outputs, or a Tuple for multi-element (insertvalue) outputs. For tuple
outputs, every element inherits `unsigned_out`; there's no per-element
type record on the circuit today, so mixed-signedness returns need a
manual `reinterpret` at the call site.
"""
function _read_output(bits, output_wires, elem_widths, unsigned_out::Bool)
    if length(elem_widths) == 1
        return _read_int(bits, output_wires, 1, elem_widths[1], unsigned_out)
    end
    starts = Vector{Int}(undef, length(elem_widths))
    s = 1
    for k in eachindex(elem_widths)
        starts[k] = s
        s += elem_widths[k]
    end
    return ntuple(k -> _read_int(bits, output_wires, starts[k], elem_widths[k], unsigned_out),
                  length(elem_widths))
end

function _read_int(bits, wires, start, width, unsigned::Bool)
    raw = UInt64(0)
    for i in 0:width-1
        raw |= UInt64(bits[wires[start + i]]) << i
    end
    if unsigned
        if width == 8;      UInt8(raw & 0xFF)
        elseif width == 16; UInt16(raw & 0xFFFF)
        elseif width == 32; UInt32(raw & 0xFFFFFFFF)
        elseif width == 64; raw
        else                raw & ((UInt64(1) << width) - 1)
        end
    else
        if width == 8;      reinterpret(Int8, UInt8(raw & 0xFF))
        elseif width == 16; reinterpret(Int16, UInt16(raw & 0xFFFF))
        elseif width == 32; reinterpret(Int32, UInt32(raw & 0xFFFFFFFF))
        elseif width == 64; reinterpret(Int64, raw)
        else                Int(raw & ((UInt64(1) << width) - 1))
        end
    end
end
