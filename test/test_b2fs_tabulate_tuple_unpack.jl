# Bennett-b2fs / U148 — `_unpack_args` in src/tabulate.jl previously
# returned a `Vector{Any}`, allocated per row of a 2^N-entry lookup
# table being built by `_tabulate_build_table`. Each row triggered an
# 8-word heap allocation + boxed elements (slow, GC-pressure'd, type-
# unstable downstream of `f(args...)`).
#
# Switched to `Tuple`-via-`ntuple` so the return is stack-allocated
# and concretely-typed once Julia specialises on the static
# `arg_types`. These tests pin:
#
#   1. `_unpack_args` returns a Tuple, not a Vector.
#   2. The tuple's element types match the declared arg_types.
#   3. The downstream `lower_tabulate` end-to-end correctness baselines
#      hold (single-arg Int8 + two-arg (Int8, Int8) tabulation, both
#      verify_reversibility green).

using Test
using Bennett
using Bennett: _unpack_args

@testset "Bennett-b2fs / U148 — _unpack_args returns Tuple" begin

    @testset "single-arg Int8 (1 arg, width 8)" begin
        # raw bits 0x05 represent Int8(5) → Tuple{Int8}.
        result = _unpack_args(UInt64(0x05), [8], Tuple{Int8}.parameters)
        @test result isa Tuple
        @test length(result) == 1
        @test result[1] === Int8(5)
        @test typeof(result[1]) === Int8
    end

    @testset "two-arg (Int8, UInt16) heterogeneous types" begin
        # raw bits: Int8(5) at offset 0, UInt16(0x0102) at offset 8.
        # packed = (0x0102 << 8) | 0x05 = 0x010205
        raw = UInt64(0x010205)
        result = _unpack_args(raw, [8, 16], Tuple{Int8, UInt16}.parameters)
        @test result isa Tuple
        @test length(result) == 2
        @test result[1] === Int8(5)
        @test result[2] === UInt16(0x0102)
        # Concrete element types — the load-bearing fix.
        @test typeof(result[1]) === Int8
        @test typeof(result[2]) === UInt16
    end

    @testset "result is NOT a Vector{Any} (regression guard)" begin
        result = _unpack_args(UInt64(0), [8], Tuple{Int8}.parameters)
        @test !(result isa Vector)
        @test !(result isa AbstractVector{Any})
    end

    @testset "end-to-end: tabulate strategy still produces correct circuits" begin
        # Single-arg tabulate (xor with const).
        c = reversible_compile(x -> x ⊻ Int8(1), Int8; strategy=:tabulate)
        @test verify_reversibility(c)
        for x in (Int8(0), Int8(5), Int8(-1), Int8(127))
            @test simulate(c, x) == (x ⊻ Int8(1)) % Int8
        end

        # Two-arg tabulate.
        c2 = reversible_compile((x, y) -> x + y, Int8, Int8; strategy=:tabulate)
        @test verify_reversibility(c2)
        for (x, y) in [(Int8(0), Int8(0)), (Int8(3), Int8(4)),
                       (Int8(-1), Int8(2))]
            @test simulate(c2, (x, y)) == (x + y) % Int8
        end
    end

    @testset "no Any[] regression in src/tabulate.jl code" begin
        # Static-inspection guard against a future refactor that
        # re-introduces `Any[]` (the actual construction pattern;
        # `Vector{Any}` as a phrase legitimately appears in the
        # current docstring explaining what was replaced).
        path = joinpath(dirname(pathof(Bennett)), "tabulate.jl")
        src  = read(path, String)
        @test !occursin("Any[]", src)
    end
end
