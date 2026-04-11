const WireIndex = Int

"""Abstract base type for reversible gates (NOT, CNOT, Toffoli). All are self-inverse."""
abstract type ReversibleGate end

"""NOT gate: flips the target bit. Self-inverse."""
struct NOTGate <: ReversibleGate
    target::WireIndex
end

"""Controlled-NOT gate: flips target when control is 1. Self-inverse."""
struct CNOTGate <: ReversibleGate
    control::WireIndex
    target::WireIndex
end

"""Toffoli gate: flips target when both controls are 1. Self-inverse. Universal for classical reversible computation."""
struct ToffoliGate <: ReversibleGate
    control1::WireIndex
    control2::WireIndex
    target::WireIndex
end

"""
    ReversibleCircuit

A reversible circuit: a sequence of NOT/CNOT/Toffoli gates operating on wires.
Produced by `reversible_compile` or `bennett`. The circuit satisfies the Bennett
invariant: all ancilla wires return to zero after execution.
"""
struct ReversibleCircuit
    n_wires::Int
    gates::Vector{ReversibleGate}
    input_wires::Vector{WireIndex}
    output_wires::Vector{WireIndex}
    ancilla_wires::Vector{WireIndex}
    input_widths::Vector{Int}
    output_elem_widths::Vector{Int}  # e.g. [8] for Int8, [8,8] for Tuple{Int8,Int8}
end
