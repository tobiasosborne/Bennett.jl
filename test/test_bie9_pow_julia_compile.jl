using Test, Bennett

# Bennett-bie9 (second half): `reversible_compile(^, Float64, Float64)` —
# the circuit for `soft_pow_julia`, the bit-exact port of Base.:^.
#
# Root cause of the "did not finish in 25 min" stall: not the circuit size
# and not loop unrolling (the extracted wrapper is 19 blocks / 20.4k
# instructions with one 31-instruction self-loop), but the arithmetic
# emitters' `sizehint!(gates, length(gates) + k)`. Since Julia 1.11
# `sizehint!` shrinks by default, so every add / multiply reallocated the
# whole gate vector down to `length + k` and copied it: lowering was
# quadratic in the total gate count (14.4M forward gates here).
#
# Invariant 1: the incremental arithmetic emitters never shrink the gate
# vector's capacity (amortised-linear emission; gates unchanged).
# Invariant 2: `^` on Float64 compiles to a reversible circuit that is
# bit-equal to Base.:^ on integer (positive / negative / zero / the n == 3
# and n == -2 special paths), non-integer, huge, negative-base, NaN, Inf
# and zero cases, with every ancilla returned to zero.

@testset "Bennett-bie9: emitters never shrink the gate vector" begin
    if VERSION >= v"1.11"
        cap(v) = length(v.ref.mem)
        emitters = [
            ("lower_add!",       (g, wa, a, b, W) -> Bennett.lower_add!(g, wa, a, b, W)),
            ("lower_add_cuccaro!", (g, wa, a, b, W) -> Bennett.lower_add_cuccaro!(g, wa, a, b, W)),
            ("lower_sub!",       (g, wa, a, b, W) -> Bennett.lower_sub!(g, wa, a, b, W)),
            ("lower_add_qcla!",  (g, wa, a, b, W) -> Bennett.lower_add_qcla!(g, wa, a, b, W)),
            ("lower_mul!",       (g, wa, a, b, W) -> Bennett.lower_mul!(g, wa, a, b, W)),
            ("lower_mul_wide!",  (g, wa, a, b, W) -> Bennett.lower_mul_wide!(g, wa, a, b, W, 2W)),
        ]
        for (name, emit!) in emitters, W in (1, 4, 8, 32, 64), big in (0, 10_000, 1_000_000)
            gates = Bennett.ReversibleGate[]
            big > 0 && sizehint!(gates, big)
            wa = Bennett.WireAllocator()
            a = Bennett.allocate!(wa, W); b = Bennett.allocate!(wa, W)
            for _ in 1:3     # repeated emission into one vector, as lower() does
                before = cap(gates)
                emit!(gates, wa, a, b, W)
                @test cap(gates) >= before   # never shrinks
            end
        end
    else
        @test_skip "capacity probe needs Julia ≥ 1.11 (Memory-backed Vector)"
    end
end

_bie9c_bits(x::Float64) = reinterpret(UInt64, x)

@testset "Bennett-bie9: reversible_compile(^, Float64, Float64)" begin
    # The inlined soft_fdiv (negative exponents) keeps its 56-step division
    # loop as a partly unrolled self-loop, so a loop bound is required.
    err = try
        reversible_compile(^, Float64, Float64); nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("max_loop_iterations not specified", sprint(showerror, err))

    c = reversible_compile(^, Float64, Float64; max_loop_iterations = 64)
    @test verify_reversibility(c; n_tests = 3)

    cases = [
        (2.0, 3.0), (1.1, 3.0),            # n == 3 special path
        (2.0, 5.0), (1.0000001, 1000.0),   # positive integer y
        (2.0, -3.0), (10.0, -2.0),         # negative integer y (division; n == -2 path)
        (0.7, -7.0),
        (1.5, 0.0), (NaN, 0.0),            # y == 0 → 1.0
        (2.0, 0.5), (3.7, 1.25),           # non-integer y
        (-2.0, 3.0), (-2.0, 2.0),          # negative base, odd / even integer y
        (-1.3, 7.0),
        (2.0, NaN), (NaN, 2.0), (1.0, NaN),
        (Inf, -1.0), (Inf, 2.0), (-Inf, 3.0),
        (0.0, -3.0), (-0.0, 3.0), (0.0, 2.5),
        (0.7, 1.0e20), (1.5, -1.0e300),    # huge |y| clamp
    ]
    for (x, y) in cases
        got = simulate(c, (_bie9c_bits(x), _bie9c_bits(y))) % UInt64
        e = x^y
        if isnan(e)
            @test isnan(reinterpret(Float64, got))
        else
            @test got == _bie9c_bits(e)
        end
    end
    # 28.8M gates / 17.2M wires: do not keep it resident in the compile cache
    # for the rest of the suite.
    c = nothing
    Bennett._clear_compile_cache!()
end
