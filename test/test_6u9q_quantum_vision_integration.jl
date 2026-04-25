# Bennett-6u9q / U146 — end-to-end integration test for the stated
# vision: `controlled ∘ reversible_compile` produces a unitary matrix
# (suitable for the Sturm.jl `when(qubit) do f(x) end` use case).
#
# The classical-reversible simulator (`simulate(cc, ctrl, x)`) only
# exercises BASIS-STATE inputs. A quantum control flow takes
# superpositions, so we want to confirm two things on a small example:
#   1. The classical permutation matrix on basis states matches what
#      Bennett.jl's `simulate` produces (no off-by-one in lifted gates).
#   2. The same circuit applied to a superposition |0⟩|x⟩|0⟩ + |1⟩|x⟩|0⟩
#      produces the expected entangled state |0⟩|x⟩|0⟩ + |1⟩|x⟩|f(x)⟩
#      and preserves norm (unitarity).
#
# This is the only test in the suite that exercises the vision
# end-to-end: compile a plain Julia function via `reversible_compile`,
# control it via `controlled`, and treat the resulting circuit as a
# 2^N × 2^N unitary on basis-state amplitudes. N is kept small enough
# (≤ 10) to make the dense statevector tractable.

using Test
using Bennett

# Avoid the LinearAlgebra stdlib dep just for `norm` — Bennett.jl's
# Project.toml [extras]/test target doesn't include it. The 2-norm
# of a complex vector is `sqrt(sum(abs2, v))` and good enough here.
_norm2(v::AbstractVector{<:Complex}) = sqrt(sum(abs2, v))

# Apply a NOT/CNOT/Toffoli gate to a `2^N`-element statevector by
# permuting basis-state amplitudes. Each gate is a permutation matrix
# on the computational basis, so the action is just an index swap; no
# materialisation of a 2^N × 2^N matrix is required.
function _apply_gate_to_statevector!(ψ::Vector{ComplexF64},
                                      g::ReversibleGate, N::Int)
    target_bit(t) = 1 << (t - 1)
    ϕ = similar(ψ)
    for b in 0:(2^N - 1)
        new_b = if g isa NOTGate
            xor(b, target_bit(g.target))
        elseif g isa CNOTGate
            if (b >> (g.control - 1)) & 1 == 1
                xor(b, target_bit(g.target))
            else
                b
            end
        else  # ToffoliGate
            c1 = (b >> (g.control1 - 1)) & 1
            c2 = (b >> (g.control2 - 1)) & 1
            if c1 == 1 && c2 == 1
                xor(b, target_bit(g.target))
            else
                b
            end
        end
        ϕ[new_b + 1] = ψ[b + 1]
    end
    copy!(ψ, ϕ)
    return ψ
end

# Initial basis state: each input wire `cc.circuit.input_wires[i]` set
# to bit i of `input_bits` (LSB-first). Returns the integer index of
# the |b⟩ basis vector.
function _basis_index(input_wires::Vector{Int}, input_bits::Integer)
    b = 0
    for (i, w) in enumerate(input_wires)
        bit = (input_bits >> (i - 1)) & 1
        b |= bit << (w - 1)
    end
    return b
end

# Read the output bit pattern from a basis-state index by gathering
# `output_wires`'s bits LSB-first.
function _read_output(output_wires::Vector{Int}, basis_idx::Int)
    out = 0
    for (i, w) in enumerate(output_wires)
        out |= ((basis_idx >> (w - 1)) & 1) << (i - 1)
    end
    return out
end

@testset "Bennett-6u9q / U146 — controlled ∘ compile is unitary on small N" begin

    # Tiniest meaningful target: a Bool→Bool function with bit_width=1.
    # Yields ~7-9 wires post-controlled, well inside 2^N statevector
    # tractability bounds.
    c  = reversible_compile(x -> !x, Bool; bit_width=1)
    cc = controlled(c)
    N  = cc.circuit.n_wires
    @test N <= 12  # sanity: keep this test tractable

    in_wires  = cc.circuit.input_wires      # [ctrl_wire, inner_input_wire]
    out_wires = cc.circuit.output_wires     # the produced bit
    @test length(in_wires) == 2
    @test in_wires[1] == cc.ctrl_wire

    @testset "basis-state behaviour matches classical simulate" begin
        # Encode (ctrl, x) into a 2-bit input_bits: bit 0 = ctrl, bit 1 = x.
        for ctrl_int in (0, 1), x_int in (0, 1)
            input_bits = (x_int << 1) | ctrl_int
            b0 = _basis_index(in_wires, input_bits)

            ψ = zeros(ComplexF64, 2^N)
            ψ[b0 + 1] = 1.0
            for g in cc.circuit.gates
                _apply_gate_to_statevector!(ψ, g, N)
            end

            # Permutation: exactly one entry is 1, rest are 0.
            nonzeros = findall(a -> abs(a) > 1e-10, ψ)
            @test length(nonzeros) == 1
            out_basis = nonzeros[1] - 1
            @test ψ[nonzeros[1]] ≈ 1.0 + 0im

            statevec_out = _read_output(out_wires, out_basis)
            classical_out = Int(simulate(cc, Bool(ctrl_int), Bool(x_int)))
            @test statevec_out == classical_out
        end
    end

    @testset "norm is preserved on a random superposition (unitarity)" begin
        # A unitary U satisfies ‖Uψ‖ = ‖ψ‖ for every ψ. Pick a random
        # complex statevector, apply the circuit, check the norm.
        ψ = randn(ComplexF64, 2^N)
        ψ ./= _norm2(ψ)
        ψ_in_norm = _norm2(ψ)
        for g in cc.circuit.gates
            _apply_gate_to_statevector!(ψ, g, N)
        end
        @test _norm2(ψ) ≈ ψ_in_norm  atol=1e-10
        @test _norm2(ψ) ≈ 1.0        atol=1e-10
    end

    @testset "superposition |0⟩|x=0⟩ + |1⟩|x=0⟩ produces |0⟩|0⟩|0⟩ + |1⟩|0⟩|f(0)⟩" begin
        # Quantum control: starting from (1/√2)(|ctrl=0,x=0⟩ + |ctrl=1,x=0⟩),
        # the controlled-! circuit should produce an entangled state where
        # the ctrl=0 branch leaves the output at 0 and the ctrl=1 branch
        # writes f(0) = 1 to the output. This is the very semantic
        # `when(qubit) do f(x) end` is meant to express in Sturm.jl.
        x_int = 0
        b00 = _basis_index(in_wires, (x_int << 1) | 0)  # ctrl=0
        b10 = _basis_index(in_wires, (x_int << 1) | 1)  # ctrl=1

        ψ = zeros(ComplexF64, 2^N)
        ψ[b00 + 1] = 1/sqrt(2)
        ψ[b10 + 1] = 1/sqrt(2)
        @test _norm2(ψ) ≈ 1.0  atol=1e-12

        for g in cc.circuit.gates
            _apply_gate_to_statevector!(ψ, g, N)
        end

        @test _norm2(ψ) ≈ 1.0  atol=1e-10

        # Find the two non-zero amplitudes and verify they match the
        # expected basis pair: one for (ctrl=0, x=0, out=0), one for
        # (ctrl=1, x=0, out=f(0)=1).
        nonzeros = findall(a -> abs(a) > 1e-10, ψ)
        @test length(nonzeros) == 2

        outputs = sort([(_read_output([in_wires[1]], n - 1),
                          _read_output(out_wires,    n - 1)) for n in nonzeros])
        # outputs is sorted by ctrl bit, so [(ctrl=0,out=0), (ctrl=1,out=1)]:
        @test outputs == [(0, 0), (1, 1)]
    end
end
