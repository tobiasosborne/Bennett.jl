# Bennett-atf4 — lower_call! derives callee arg types from methods() instead
# of hardcoding UInt64.
#
# RED → GREEN TDD per CLAUDE.md §3 + docs/design/alpha_consensus.md §5.
#
# Test cases:
#   T1. Int8 scalar arg — fails today at MethodError from the hardcoded
#       Tuple{UInt64, ...} derivation; GREEN post-fix.
#   T2. NTuple{9,UInt64} arg (linear_scan_pmap_set live repro from
#       p6_research_local.md §2.6) — must get past lower.jl:1870 post-fix.
#       Downstream sret error is Bennett-0c8o / Bennett-uyf9; we tolerate it.
#   T3. Width-matching assertion fires loud with clear context.
#   T4. Vararg callee rejected cleanly.
#   T5. Multi-method callee rejected cleanly.
#   R1. Regression: soft_fma still derives Tuple{UInt64, UInt64, UInt64}.
#   R2. Arity mismatch rejected cleanly.

using Test
using Bennett
using Bennett: IRCall, IROperand, ssa, iconst, lower_call!, WireAllocator,
               ReversibleGate, allocate!, register_callee!
using Bennett: _callee_arg_types, _assert_arg_widths_match

@testset "Bennett-atf4 lower_call! non-trivial arg types" begin

    # T1: Int8 scalar arg — hardcoded-UInt64 assumption broken.
    @testset "T1: Int8 scalar callee compiles" begin
        int8_identity(x::Int8)::Int8 = x
        register_callee!(int8_identity)

        inst = IRCall(:res, int8_identity, [ssa(:x)], [8], 8)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:x] = allocate!(wa, 8)

        @test_nowarn lower_call!(gates, wa, vw, inst)
        @test haskey(vw, :res)
        @test length(vw[:res]) == 8
    end

    # T2: NTuple{9,UInt64} arg — the bead's live repro.
    # Must get past line 1870. Downstream sret error is Bennett-0c8o/uyf9.
    @testset "T2: NTuple{9,UInt64} arg gets past line 1870" begin
        inst = IRCall(:res, Bennett.linear_scan_pmap_set,
                      [ssa(:state), ssa(:k), ssa(:v)],
                      [576, 8, 8], 576)

        # Helper gives the right type.
        T = _callee_arg_types(inst)
        @test T === Tuple{NTuple{9,UInt64}, Int8, Int8}

        # Width-match assertion passes for matching widths.
        @test _assert_arg_widths_match(inst, T) === nothing

        # Full call — must not MethodError at 1870. Downstream sret error
        # is expected until Bennett-0c8o + Bennett-uyf9 land.
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:state] = allocate!(wa, 576)
        vw[:k]     = allocate!(wa, 8)
        vw[:v]     = allocate!(wa, 8)

        err_msg = try
            lower_call!(gates, wa, vw, inst)
            ""
        catch e
            sprint(showerror, e)
        end
        @test !occursin("no unique matching method found", err_msg)
        if !isempty(err_msg)
            @test occursin("sret", err_msg) ||
                  occursin("VectorType", err_msg) ||
                  occursin("memcpy", err_msg)
        end
    end

    # T3: width-matching assertion fires with clear context.
    @testset "T3: arg-width mismatch fires loud" begin
        # soft_fma takes (UInt64, UInt64, UInt64). Bogus 32 in slot 2.
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)],
                      [64, 32, 64],
                      64)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:a] = allocate!(wa, 64)
        vw[:b] = allocate!(wa, 32)
        vw[:c] = allocate!(wa, 64)

        e = try
            lower_call!(gates, wa, vw, inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("arg width mismatch", msg)
        @test occursin("#2", msg)
        @test occursin("32", msg)
        @test occursin("UInt64", msg)
        @test occursin("soft_fma", msg)
    end

    # T4: vararg callee rejected.
    @testset "T4: vararg callee rejected" begin
        vararg_stub(a::UInt64, rest::UInt64...) = a
        @test Base.isvarargtype(first(methods(vararg_stub)).sig.parameters[end])

        inst = IRCall(:res, vararg_stub, [ssa(:a), ssa(:b)], [64, 64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        @test occursin("Vararg", sprint(showerror, e))
    end

    # T5: multi-method callee rejected.
    @testset "T5: multi-method callee rejected" begin
        multimethod_stub(x::UInt64) = x
        multimethod_stub(x::UInt64, y::UInt64) = x + y
        @test length(methods(multimethod_stub)) == 2

        inst = IRCall(:res, multimethod_stub, [ssa(:x)], [64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("2 methods", msg)
    end

    # R1: regression — soft_fma derivation unchanged.
    @testset "R1: soft_fma derivation unchanged" begin
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)], [64, 64, 64], 64)
        T = _callee_arg_types(inst)
        @test T === Tuple{UInt64, UInt64, UInt64}
    end

    # R2: arity mismatch rejected.
    @testset "R2: arity mismatch rejected" begin
        inst = IRCall(:res, Bennett.soft_fma, [ssa(:a), ssa(:b)], [64, 64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("arity", msg)
        @test occursin("3", msg)
        @test occursin("2", msg)
    end
end
