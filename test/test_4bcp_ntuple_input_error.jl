# Bennett-4bcp / U102 — actionable error for NTuple-typed arg ambiguity.
#
# `NTuple{N,T}` is `Tuple{T,T,...,T}`, so `reversible_compile(f, NTuple{2,Int8})`
# dispatches as the 2-arg interpretation `arg_types=Tuple{Int8,Int8}`. If f
# actually takes a single tuple-typed argument, code_llvm later throws
# "no unique matching method" with no hint about the wrap fix. The pre-IR
# `hasmethod` check rewrites that into an actionable ArgumentError.

@testset "Bennett-4bcp / U102 — NTuple-input actionable error" begin
    # f takes a single NTuple{2,Int8}; the user's natural call form is ambiguous.
    f4bcp(t::NTuple{2,Int8}) = t[1] + t[2]

    @testset "ambiguous NTuple input → actionable error" begin
        err = try
            reversible_compile(f4bcp, NTuple{2,Int8})
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("Bennett-4bcp", msg)
        @test occursin("Tuple{Tuple{Int8, Int8}}", msg) || occursin("Tuple{NTuple{2, Int8}}", msg)
        @test occursin("single tuple-typed arg", msg) || occursin("tuple-typed", msg)
    end

    @testset "explicit Tuple{NTuple} wrap still compiles" begin
        c = reversible_compile(f4bcp, Tuple{NTuple{2,Int8}})
        @test verify_reversibility(c)
        @test gate_count(c).total > 0
    end

    @testset "regular multi-arg back-compat" begin
        g4bcp(a::Int8, b::Int8) = a + b
        c = reversible_compile(g4bcp, Int8, Int8)
        @test verify_reversibility(c)
        @test gate_count(c).total > 0
    end

    @testset "no-method falls through to plain error" begin
        h4bcp(t::NTuple{2,Int8}) = t[1] + t[2]
        err = try
            reversible_compile(h4bcp, Int32)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("no method", msg)
        @test occursin("Tuple{Int32}", msg)
        # Should NOT suggest the wrap (h4bcp doesn't take Tuple{Int32} either).
        @test !occursin("single tuple-typed arg", msg)
    end
end
