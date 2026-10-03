using Test
using Random
using Bennett
using Bennett: ReversibleGate, WireAllocator, allocate!, lower_add_qcla!

# Bennett-retr — `add=:qcla` with aliased operands (`x + x`, `z + z`).
#
# `lower_add_qcla!` turns `b` into the propagate register in place
# (`CNOT(a[k], b[k])`, phases 2 and 5). When the dispatcher handed it the same
# wires for `a` and `b` (an `add %x, %x` under `optimize=false`; LLVM rewrites
# it to `shl` under `optimize=true`), those became `CNOT(w, w)`: pre-Bennett-lcye
# a dirty ancilla on 254/256 Int8 inputs, post-lcye a construction-time
# ArgumentError on a valid program. Fix: the dispatcher copies `b` to fresh
# wires on any overlap (as the Cuccaro path does), and the primitive rejects
# overlapping / repeated-wire operands loudly.
#
# The other adder / multiplier strategies were swept with the same witness and
# are pinned here too (all were already correct).

_retr_zz(x::Int8) = (z = x ⊻ Int8(0x35); z + z)
_retr_zm(x::Int8) = (z = x ⊻ Int8(0x35); z * z)

function _retr_check_int8(f, kw)
    for opt in (false, true)
        c = reversible_compile(f, Int8; optimize=opt, kw...)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c)
    end
end

@testset "Bennett-retr: aliased add operands (exhaustive Int8)" begin
    for s in (:ripple, :cuccaro, :qcla)
        @testset "add=$s x+x" begin
            _retr_check_int8(x::Int8 -> x + x, (add=s,))
        end
        @testset "add=$s z+z (non-argument operand)" begin
            _retr_check_int8(_retr_zz, (add=s,))
        end
    end
    for s in (:shift_add, :qcla_tree)
        @testset "mul=$s x*x" begin
            _retr_check_int8(x::Int8 -> x * x, (mul=s,))
        end
        @testset "mul=$s z*z" begin
            _retr_check_int8(_retr_zm, (mul=s,))
        end
    end
end

@testset "Bennett-retr: add=:qcla x+x at wider widths" begin
    rng = MersenneTwister(0x7e72)
    for T in (Int16, Int32, Int64)
        f = x -> x + x
        c = reversible_compile(f, T; add=:qcla, optimize=false)
        xs = T[0, 1, -1, typemin(T), typemax(T), typemin(T) + 1, typemax(T) - 1]
        append!(xs, rand(rng, T, 64))
        for x in xs
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c)
    end
end

@testset "Bennett-retr: lower_add_qcla! rejects overlapping operands" begin
    for W in (1, 2, 4, 8)
        gates = ReversibleGate[]
        wa = WireAllocator()
        a = allocate!(wa, W)
        @test_throws ArgumentError lower_add_qcla!(gates, wa, a, a, W)
        if W >= 2
            b = allocate!(wa, W)
            b[1] = a[2]                       # partial overlap
            @test_throws ArgumentError lower_add_qcla!(gates, wa, a, b, W)
            r = copy(a); r[2] = r[1]          # repeated wire inside one operand
            @test_throws ArgumentError lower_add_qcla!(gates, wa, r, allocate!(wa, W), W)
        end
    end
end
